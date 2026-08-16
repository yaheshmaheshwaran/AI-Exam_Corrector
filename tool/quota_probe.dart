// Which models can this key use right now?
//
//   dart run tool/quota_probe.dart              # every model in the chain
//   dart run tool/quota_probe.dart <model> …    # specific models
//
// Sends one tiny request per model, so it costs one request from each model's
// daily allowance. A diagnostic, not something the application runs.
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import 'package:exam_corrector/core/config/app_config.dart';
import 'package:exam_corrector/core/constants/app_constants.dart';

Future<void> main(List<String> args) async {
  final AppConfig config = await AppConfig.load();
  if (!config.hasApiKey) {
    stderr.writeln('No API key resolved.');
    exit(1);
  }

  final List<String> models = args.isNotEmpty ? args : config.modelChain;
  stdout.writeln('Checking ${models.length} model(s) with the configured key.');
  stdout.writeln('');

  for (final String model in models) {
    final String verdict = await _check(config.apiKey!, model);
    stdout.writeln('${model.padRight(26)} $verdict');
  }

  stdout.writeln('');
  stdout.writeln('Daily free-tier allowances reset at midnight Pacific time.');
}

Future<String> _check(String apiKey, String model) async {
  final http.Response response;
  try {
    response = await http.post(
      Uri.parse(AppConstants.apiEndpoint),
      headers: <String, String>{
        'content-type': 'application/json',
        'x-goog-api-key': apiKey,
      },
      body: jsonEncode(<String, Object?>{
        'model': model,
        'store': false,
        'input': 'Reply with the single word OK.',
        'generation_config': <String, Object?>{'max_output_tokens': 2000},
      }),
    );
  } on IOException catch (error) {
    return 'unreachable ($error)';
  }

  if (response.statusCode == 200) return 'ok — quota available';

  final String detail = _message(response.body);
  switch (response.statusCode) {
    case 429:
      final RegExp limit = RegExp(r'limit:\s*(\d+)');
      final RegExp retry = RegExp(r'retry in ([0-9.]+)s', caseSensitive: false);
      final String? cap = limit.firstMatch(detail)?.group(1);
      final String? wait = retry.firstMatch(detail)?.group(1);
      return 'EXHAUSTED'
          '${cap == null ? '' : ' — limit $cap'}'
          '${wait == null ? '' : ', retry in ${double.parse(wait).ceil()}s'}';
    case 404:
      return 'not available to this key';
    case 401:
    case 403:
      return 'key rejected — $detail';
    default:
      return '${response.statusCode} — $detail';
  }
}

String _message(String body) {
  try {
    final Object? decoded = jsonDecode(body);
    if (decoded is Map<String, dynamic>) {
      final Object? error = decoded['error'];
      if (error is Map<String, dynamic> && error['message'] is String) {
        final String message = error['message'] as String;
        return message.length > 120 ? '${message.substring(0, 120)}…' : message;
      }
    }
  } on FormatException {
    // Fall through to the raw body.
  }
  return body.length > 120 ? '${body.substring(0, 120)}…' : body;
}
