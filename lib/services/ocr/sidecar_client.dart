import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import 'package:exam_corrector/core/async/cancellation.dart';
import 'package:exam_corrector/core/errors/app_exception.dart';
import 'package:exam_corrector/services/ocr/sidecar_process_service.dart';

/// Progress from the sidecar: a message, and how far through, 0..1.
typedef SidecarProgress = void Function(String message, double fraction);

/// Talks to the local Python sidecar's region-centric endpoints.
///
/// The document renderer, the local layout detector, the handwriting
/// recogniser and the cropper all share this: one process, one token, one
/// way of streaming progress back.
class SidecarClient {
  SidecarClient({
    required SidecarProcessService process,
    http.Client? client,
    this.idleTimeout = const Duration(minutes: 10),
  })  : _process = process,
        _injectedClient = client;

  final SidecarProcessService _process;
  final http.Client? _injectedClient;

  /// Bounds the silence between events, not the whole call: recognising a
  /// long script legitimately takes many minutes.
  final Duration idleTimeout;

  Future<SidecarEndpoint> endpoint({void Function(String message)? onProgress}) =>
      _process.ensureRunning(onProgress: onProgress);

  /// Posts [body] to a streaming endpoint and returns its `done` event.
  Future<Map<String, Object?>> stream(
    String path,
    Map<String, Object?> body, {
    SidecarProgress? onProgress,
    CancellationToken? cancel,
  }) async {
    final SidecarEndpoint target = await endpoint(
      onProgress: (String message) => onProgress?.call(message, 0),
    );
    cancel?.throwIfCancelled();

    final http.Client client = _injectedClient ?? http.Client();
    final void Function()? unregister = cancel?.onCancel(() {
      if (_injectedClient == null) client.close();
    });

    try {
      final http.Request request = http.Request('POST', target.resolve(path));
      request.headers.addAll(<String, String>{
        'content-type': 'application/json',
        'accept': 'text/event-stream',
        ...target.authHeaders,
      });
      request.body = jsonEncode(body);

      final http.StreamedResponse response = await client.send(request);
      if (response.statusCode != 200) {
        throw OcrException(
          _messageForStatus(response.statusCode, await response.stream.bytesToString()),
        );
      }

      final Stream<String> lines = response.stream
          .timeout(idleTimeout)
          .transform(utf8.decoder)
          .transform(const LineSplitter());

      await for (final String line in lines) {
        cancel?.throwIfCancelled();
        if (!line.startsWith('data:')) continue;
        final String data = line.substring(5).trim();
        if (data.isEmpty) continue;

        final Object? decoded;
        try {
          decoded = jsonDecode(data);
        } on FormatException {
          continue;
        }
        if (decoded is! Map<String, dynamic>) continue;

        switch (decoded['type']) {
          case 'progress':
            final Object? message = decoded['message'];
            final Object? fraction = decoded['fraction'];
            if (message is String) {
              onProgress?.call(message, fraction is num ? fraction.toDouble() : 0);
            }
          case 'done':
            return decoded;
          case 'error':
            final Object? message = decoded['message'];
            final Object? page = decoded['page'];
            throw PipelineException(
              message is String ? message : 'The recogniser failed.',
              page: page is int ? page : null,
            );
        }
      }

      throw const OcrException(
        'The recogniser stopped without finishing. Try again.',
      );
    } on AppException {
      rethrow;
    } on TimeoutException {
      throw const OcrException(
        'The recogniser stopped responding. Try again, or reduce the scan '
        'resolution in Settings.',
      );
    } on SocketException {
      throw const OcrException(
        'Lost contact with the recogniser.',
        sidecarUnavailable: true,
      );
    } on http.ClientException {
      if (cancel?.isCancelled ?? false) throw const CancelledException();
      throw const OcrException(
        'The connection to the recogniser was lost before it finished.',
      );
    } finally {
      unregister?.call();
      if (_injectedClient == null) client.close();
    }
  }

  /// Posts [body] to a plain JSON endpoint.
  Future<Map<String, Object?>> post(
    String path,
    Map<String, Object?> body,
  ) async {
    final SidecarEndpoint target = await endpoint();
    final http.Client client = _injectedClient ?? http.Client();
    try {
      final http.Response response = await client
          .post(
            target.resolve(path),
            headers: <String, String>{
              'content-type': 'application/json',
              ...target.authHeaders,
            },
            body: jsonEncode(body),
          )
          .timeout(const Duration(minutes: 2));
      if (response.statusCode != 200) {
        throw OcrException(_messageForStatus(response.statusCode, response.body));
      }
      final Object? decoded = jsonDecode(response.body);
      if (decoded is! Map<String, dynamic>) {
        throw const OcrException('The recogniser sent an unexpected response.');
      }
      return decoded;
    } on AppException {
      rethrow;
    } on FormatException {
      throw const OcrException('The recogniser sent an unreadable response.');
    } on TimeoutException {
      throw const OcrException('The recogniser stopped responding.');
    } on SocketException {
      throw const OcrException(
        'Lost contact with the recogniser.',
        sidecarUnavailable: true,
      );
    } finally {
      if (_injectedClient == null) client.close();
    }
  }

  Future<void> dispose() => _process.stop();

  String _messageForStatus(int status, String body) {
    if (status == 401) {
      return 'The recogniser rejected the connection. Restart the application.';
    }
    if (status == 404) {
      return 'The recogniser is out of date — it does not know this request. '
          'Update ocr_service to match the application.';
    }
    try {
      final Object? decoded = jsonDecode(body);
      if (decoded is Map<String, dynamic> && decoded['detail'] is String) {
        return decoded['detail'] as String;
      }
    } on FormatException {
      // Not JSON.
    }
    return 'The recogniser returned an error (HTTP $status).';
  }
}
