import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:http/http.dart' as http;

import 'package:exam_corrector/core/errors/app_exception.dart';

/// A running sidecar: where to reach it, and the token it expects.
class SidecarEndpoint {
  const SidecarEndpoint({required this.baseUrl, required this.token});

  final Uri baseUrl;
  final String token;

  Uri resolve(String path) => baseUrl.resolve(path);

  Map<String, String> get authHeaders => <String, String>{'x-ocr-token': token};
}

/// Owns the Python OCR process.
///
/// Started lazily, on the first scanned paper — importing torch costs seconds
/// and hundreds of megabytes, which a teacher marking text-layer PDFs should
/// never pay. Once up it stays up for the session, because that cost is paid
/// per process, not per document.
class SidecarProcessService {
  SidecarProcessService({
    this.startupTimeout = const Duration(seconds: 90),
    http.Client? client,
    this.externalEndpoint,
  }) : _client = client ?? http.Client();

  /// An already-running recogniser to use instead of starting one — a shared
  /// machine with a GPU, or a sidecar started by hand while debugging. Read on
  /// every call so a change in configuration applies immediately.
  final SidecarEndpoint? Function()? externalEndpoint;

  /// Generous by necessity: the first start on a cold machine imports torch and
  /// may still be resolving model weights.
  final Duration startupTimeout;

  final http.Client _client;

  Process? _process;
  SidecarEndpoint? _endpoint;
  Future<SidecarEndpoint>? _starting;

  bool get isRunning => _endpoint != null;

  /// Returns a live endpoint, starting the process if it is not up yet.
  ///
  /// Concurrent callers share one start rather than racing to spawn two
  /// processes that would then fight over the port.
  Future<SidecarEndpoint> ensureRunning({
    void Function(String message)? onProgress,
  }) {
    final SidecarEndpoint? external = externalEndpoint?.call();
    if (external != null) return _checkExternal(external);

    final SidecarEndpoint? live = _endpoint;
    if (live != null) return Future<SidecarEndpoint>.value(live);

    return _starting ??= _start(onProgress: onProgress).whenComplete(() {
      _starting = null;
    });
  }

  Future<SidecarEndpoint> _checkExternal(SidecarEndpoint endpoint) async {
    try {
      final http.Response response = await _client
          .get(endpoint.resolve('health'), headers: endpoint.authHeaders)
          .timeout(const Duration(seconds: 5));
      if (response.statusCode == 200) return endpoint;
      throw OcrException(
        'The recogniser at ${endpoint.baseUrl} refused the connection '
        '(HTTP ${response.statusCode}). Check EXAM_CORRECTOR_OCR_TOKEN.',
        sidecarUnavailable: true,
      );
    } on OcrException {
      rethrow;
    } on Object {
      throw OcrException(
        'The recogniser at ${endpoint.baseUrl} is not answering.',
        sidecarUnavailable: true,
      );
    }
  }

  Future<SidecarEndpoint> _start({
    void Function(String message)? onProgress,
  }) async {
    final _SidecarCommand command = _resolveCommand();

    onProgress?.call('Starting the handwriting recogniser…');

    final int port = await _freePort();
    final String token = _newToken();

    final Process process;
    try {
      process = await Process.start(
        command.executable,
        <String>[
          ...command.arguments,
          '--port',
          '$port',
          '--token',
          token,
          // The sidecar exits by itself if this app is killed rather than
          // closed, instead of holding its model weights until a restart.
          '--parent-pid',
          '$pid',
        ],
        workingDirectory: command.workingDirectory,
      );
    } on ProcessException catch (error) {
      throw OcrException(
        'The handwriting recogniser could not be started: ${error.message}',
        sidecarUnavailable: true,
      );
    }

    _process = process;

    // Drained so the pipes cannot fill and stall the child. Its stderr is the
    // only diagnostic when a model fails to load, so it goes to the console.
    process.stdout.transform(utf8.decoder).listen((_) {});
    process.stderr.transform(utf8.decoder).listen(stderr.write);

    unawaited(
      process.exitCode.then((int code) {
        if (identical(_process, process)) {
          _process = null;
          _endpoint = null;
        }
      }),
    );

    final SidecarEndpoint endpoint = SidecarEndpoint(
      baseUrl: Uri.parse('http://127.0.0.1:$port/'),
      token: token,
    );

    await _awaitHealthy(endpoint, process, onProgress: onProgress);

    _endpoint = endpoint;
    return endpoint;
  }

  Future<void> _awaitHealthy(
    SidecarEndpoint endpoint,
    Process process, {
    void Function(String message)? onProgress,
  }) async {
    final DateTime deadline = DateTime.now().add(startupTimeout);
    bool announced = false;

    while (DateTime.now().isBefore(deadline)) {
      // A process that has already exited will never become healthy; failing
      // now beats waiting out the full timeout.
      if (_process == null) {
        throw const OcrException(
          'The handwriting recogniser stopped before it was ready. Check that '
          'its Python environment is installed — see ocr_service/README.md.',
          sidecarUnavailable: true,
        );
      }

      try {
        final http.Response response = await _client
            .get(endpoint.resolve('health'), headers: endpoint.authHeaders)
            .timeout(const Duration(seconds: 2));
        if (response.statusCode == 200) return;
      } on Object {
        // Not up yet. Keep polling until the deadline.
      }

      if (!announced) {
        announced = true;
        onProgress?.call('Waiting for the handwriting recogniser to load…');
      }

      await Future<void>.delayed(const Duration(milliseconds: 250));
    }

    await stop();
    throw OcrException(
      'The handwriting recogniser did not start within '
      '${startupTimeout.inSeconds} seconds.',
      sidecarUnavailable: true,
    );
  }

  /// Loads the recognition weights ahead of the first document.
  ///
  /// Worth doing separately because a first run downloads well over a gigabyte,
  /// and a teacher should be told that plainly rather than watching an
  /// apparently stalled correction.
  Future<void> warmup(
    SidecarEndpoint endpoint, {
    required String model,
    void Function(String message)? onProgress,
  }) async {
    onProgress?.call('Preparing the handwriting model…');
    try {
      await _client.post(
        endpoint.resolve('warmup').replace(
          queryParameters: <String, String>{'model': model},
        ),
        headers: endpoint.authHeaders,
      );
    } on Object {
      // A failed warm-up is not fatal: the extract call loads the model too,
      // and its error message is the more useful one to surface.
    }
  }

  /// Asks the process to exit, then makes sure it did.
  Future<void> stop() async {
    final Process? process = _process;
    final SidecarEndpoint? endpoint = _endpoint;

    _process = null;
    _endpoint = null;

    if (process == null) return;

    if (endpoint != null) {
      try {
        await _client
            .post(endpoint.resolve('shutdown'), headers: endpoint.authHeaders)
            .timeout(const Duration(seconds: 2));
      } on Object {
        // Falling through to the signal below is the point of the try.
      }
    }

    try {
      await process.exitCode.timeout(const Duration(seconds: 3));
    } on TimeoutException {
      process.kill(ProcessSignal.sigkill);
    }
  }

  void dispose() {
    unawaited(stop());
    _client.close();
  }

  /// Binds port zero to have the OS name a free port, then hands it to the
  /// child. A tiny race remains, which is why startup failures are retried by
  /// the caller rather than treated as fatal.
  Future<int> _freePort() async {
    final ServerSocket probe =
        await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final int port = probe.port;
    await probe.close();
    return port;
  }

  String _newToken() {
    final Random random = Random.secure();
    final List<int> bytes =
        List<int>.generate(24, (_) => random.nextInt(256));
    return base64Url.encode(bytes);
  }

  /// Finds the sidecar: an explicit override, a bundled build, or the
  /// development virtual environment, in that order.
  _SidecarCommand _resolveCommand() {
    final String override =
        Platform.environment['EXAM_CORRECTOR_OCR_COMMAND']?.trim() ?? '';
    if (override.isNotEmpty) {
      return _SidecarCommand(executable: override, arguments: const <String>[]);
    }

    final _SidecarCommand? bundled = _bundledCommand();
    if (bundled != null) return bundled;

    final _SidecarCommand? development = _developmentCommand();
    if (development != null) return development;

    throw const OcrException(
      'The handwriting recogniser is not installed. Create its environment '
      'with:  uv venv --python 3.12 ocr_service/.venv  and install '
      'ocr_service/requirements.txt.',
      sidecarUnavailable: true,
    );
  }

  _SidecarCommand? _bundledCommand() {
    final Directory executableDir =
        File(Platform.resolvedExecutable).parent;

    final List<String> candidates = <String>[
      // macOS: Contents/MacOS/<app> → Contents/Resources/ocr_service/
      '${executableDir.parent.path}/Resources/ocr_service/exam-corrector-ocr',
      // Windows and Linux: alongside the executable.
      '${executableDir.path}/ocr_service/exam-corrector-ocr.exe',
      '${executableDir.path}/ocr_service/exam-corrector-ocr',
    ];

    for (final String candidate in candidates) {
      if (File(candidate).existsSync()) {
        return _SidecarCommand(
          executable: candidate,
          arguments: const <String>[],
        );
      }
    }
    return null;
  }

  _SidecarCommand? _developmentCommand() {
    final Directory? root = _projectRoot();
    if (root == null) return null;

    final String service = '${root.path}/ocr_service';
    final String python = Platform.isWindows
        ? '$service/.venv/Scripts/python.exe'
        : '$service/.venv/bin/python';

    if (!File(python).existsSync()) return null;
    if (!File('$service/app.py').existsSync()) return null;

    return _SidecarCommand(
      executable: python,
      arguments: <String>['app.py'],
      workingDirectory: service,
    );
  }

  /// Walks up looking for `pubspec.yaml`, the same way [AppConfig] locates
  /// the project's `.env`: from the working directory, then from the
  /// executable — an app opened from Finder runs with `/` as its working
  /// directory, its executable deep inside the project's `build/`.
  Directory? _projectRoot() {
    for (final Directory start in <Directory>[
      Directory.current,
      File(Platform.resolvedExecutable).parent,
    ]) {
      Directory directory = start;
      for (int depth = 0; depth < 12; depth++) {
        if (File('${directory.path}/pubspec.yaml').existsSync()) return directory;
        final Directory parent = directory.parent;
        if (parent.path == directory.path) break;
        directory = parent;
      }
    }
    return null;
  }
}

class _SidecarCommand {
  const _SidecarCommand({
    required this.executable,
    required this.arguments,
    this.workingDirectory,
  });

  final String executable;
  final List<String> arguments;
  final String? workingDirectory;
}
