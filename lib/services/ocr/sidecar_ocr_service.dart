import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import 'package:exam_corrector/core/config/app_config.dart';
import 'package:exam_corrector/core/errors/app_exception.dart';
import 'package:exam_corrector/models/ocr/document_transcript.dart';
import 'package:exam_corrector/services/ocr/ocr_service.dart';
import 'package:exam_corrector/services/ocr/sidecar_process_service.dart';
import 'package:exam_corrector/services/ocr/transcript_parser.dart';

/// [OcrService] backed by the local Python sidecar running TrOCR.
///
/// Reads its configuration through a callback, matching
/// [GeminiCorrectionService], so a change made in Settings applies to the next
/// document without a restart.
class SidecarOcrService implements OcrService {
  SidecarOcrService(
    this._configProvider, {
    SidecarProcessService? sidecar,
    TranscriptParser parser = const TranscriptParser(),
    http.Client? client,
  })  : _sidecar = sidecar ?? SidecarProcessService(),
        _parser = parser,
        _injectedClient = client;

  final AppConfig Function() _configProvider;
  final SidecarProcessService _sidecar;
  final TranscriptParser _parser;
  final http.Client? _injectedClient;

  AppConfig get _config => _configProvider();

  /// Recognition can legitimately run for minutes on a long script. This bounds
  /// the gap between progress events, not the run as a whole.
  static const Duration _idleTimeout = Duration(minutes: 10);

  @override
  Future<DocumentTranscript> transcribe({
    required String path,
    OcrProgress? onProgress,
  }) async {
    final SidecarEndpoint endpoint = await _sidecar.ensureRunning(
      onProgress: (String message) => onProgress?.call(message, 0),
    );

    await _sidecar.warmup(
      endpoint,
      model: _config.trocrModel,
      onProgress: (String message) => onProgress?.call(message, 0),
    );

    final Directory workdir = await _createWorkdir();
    final http.Client client = _injectedClient ?? http.Client();

    try {
      final http.Request request = http.Request(
        'POST',
        endpoint.resolve('extract'),
      );
      request.headers.addAll(<String, String>{
        'content-type': 'application/json',
        'accept': 'text/event-stream',
        ...endpoint.authHeaders,
      });
      request.body = jsonEncode(<String, Object?>{
        'path': path,
        'dpi': _config.ocrDpi,
        'model': _config.trocrModel,
        'workdir': workdir.path,
      });

      final http.StreamedResponse response = await client.send(request);

      if (response.statusCode != 200) {
        final String body = await response.stream.bytesToString();
        throw OcrException(_messageForStatus(response.statusCode, body));
      }

      final Object? document = await _readStream(
        response.stream,
        onProgress: onProgress,
      );

      return _parser.parse(document);
    } on OcrException {
      rethrow;
    } on TimeoutException {
      throw const OcrException(
        'The handwriting recogniser stopped responding. Try again, or reduce '
        'the scan resolution in Settings.',
      );
    } on SocketException {
      throw const OcrException(
        'Lost contact with the handwriting recogniser.',
        sidecarUnavailable: true,
      );
    } on http.ClientException {
      throw const OcrException(
        'The connection to the handwriting recogniser was lost before it '
        'finished reading the paper.',
      );
    } finally {
      if (_injectedClient == null) client.close();
    }
  }

  /// Consumes the sidecar's event stream, forwarding progress and returning the
  /// finished document.
  Future<Object?> _readStream(
    http.ByteStream body, {
    OcrProgress? onProgress,
  }) async {
    final Stream<String> lines = body
        .timeout(_idleTimeout)
        .transform(utf8.decoder)
        .transform(const LineSplitter());

    Object? document;

    await for (final String line in lines) {
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
            onProgress?.call(
              message,
              fraction is num ? fraction.toDouble() : 0,
            );
          }
        case 'done':
          document = decoded['document'];
        case 'error':
          final Object? message = decoded['message'];
          throw OcrException(
            message is String
                ? message
                : 'The handwriting recogniser failed to read this document.',
          );
      }
    }

    if (document == null) {
      throw const OcrException(
        'The handwriting recogniser ended without returning a transcript.',
      );
    }

    return document;
  }

  String _messageForStatus(int status, String body) {
    if (status == 401) {
      return 'The handwriting recogniser rejected the connection. Restart the '
          'application.';
    }
    if (status == 503) {
      return 'The handwriting model could not be loaded. On a first run it '
          'must download about 1.4 GB — check your internet connection.';
    }

    final String detail = _detailFrom(body);
    return detail.isEmpty
        ? 'The handwriting recogniser returned an error (HTTP $status).'
        : detail;
  }

  String _detailFrom(String body) {
    try {
      final Object? decoded = jsonDecode(body);
      if (decoded is Map<String, dynamic>) {
        final Object? detail = decoded['detail'];
        if (detail is String) return detail;
      }
    } on FormatException {
      // Not JSON; nothing useful to pull out.
    }
    return '';
  }

  /// Page images and line crops outlive this call: the review screen reads them
  /// back from disk, so the directory is only cleared when the app is done with
  /// the paper.
  Future<Directory> _createWorkdir() async {
    return Directory.systemTemp.createTemp('exam_corrector_ocr_');
  }

  @override
  Future<void> dispose() => _sidecar.stop();
}
