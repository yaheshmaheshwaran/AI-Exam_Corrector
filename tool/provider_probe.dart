// Phase 0 probe: what an OpenAI-compatible provider accepts, before the new
// client is built on it.
//
//   dart run tool/provider_probe.dart                 (Gemini)
//   dart run tool/provider_probe.dart nvidia          (NVIDIA NIM, needs NVIDIA_API_KEY)
//   PROBE_MODEL=gemini-3.6-flash dart run tool/provider_probe.dart
//
// It lists the models the key can use (free), then sends ONE small request:
// a rendered page image with a JSON-schema answer, and prints how the
// provider answered — including the raw error body if it refuses, which is
// what the client's quota handling has to read.
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

const Map<String, ({String base, String keyName})> _providers = <String, ({String base, String keyName})>{
  'gemini': (base: 'https://generativelanguage.googleapis.com/v1beta/openai', keyName: 'GEMINI_API_KEY'),
  'nvidia': (base: 'https://integrate.api.nvidia.com/v1', keyName: 'NVIDIA_API_KEY'),
};

Future<void> main(List<String> args) async {
  final String name = args.isEmpty ? 'gemini' : args.first;
  final ({String base, String keyName})? provider = _providers[name];
  if (provider == null) {
    stderr.writeln('Unknown provider "$name". Use one of: ${_providers.keys.join(', ')}.');
    exitCode = 64;
    return;
  }
  final Map<String, String> env = <String, String>{..._dotEnv(), ...Platform.environment};
  final String key = env[provider.keyName] ?? (name == 'gemini' ? env['GOOGLE_API_KEY'] ?? '' : '');
  if (key.isEmpty) {
    stderr.writeln('${provider.keyName} is not set in .env or the environment.');
    exitCode = 78;
    return;
  }
  final Map<String, String> auth = <String, String>{'authorization': 'Bearer $key'};

  // 1. Models — free.
  final http.Response models = await http.get(Uri.parse('${provider.base}/models'), headers: auth);
  stdout.writeln('GET /models → ${models.statusCode}');
  final List<String> ids = <String>[];
  if (models.statusCode == 200) {
    final Object? body = jsonDecode(models.body);
    if (body is Map && body['data'] is List) {
      for (final Object? item in body['data'] as List<Object?>) {
        if (item is Map && item['id'] is String) ids.add(item['id'] as String);
      }
    }
    final Iterable<String> shown = name == 'gemini'
        ? ids.where((String id) => id.contains('flash') || id.contains('pro'))
        : ids.where((String id) => RegExp('kimi|glm|deepseek|qwen').hasMatch(id));
    stdout.writeln('  ${ids.length} models; relevant:');
    for (final String id in shown) {
      stdout.writeln('    $id');
    }
  } else {
    stdout.writeln('  ${_short(models.body)}');
  }

  // 2. One request: an image and a JSON-schema answer.
  final String model = env['PROBE_MODEL'] ??
      (name == 'gemini'
          ? ids.map((String id) => id.replaceFirst('models/', '')).firstWhere(
              (String id) => id.contains('flash-lite') && !id.contains('preview'),
              orElse: () => 'gemini-3.6-flash')
          : 'moonshotai/kimi-k3');
  final File page = File('build/render-check/page_005.jpg');
  if (!page.existsSync()) {
    stderr.writeln('Run `dart run tool/render_probe_dart.dart` first: it renders the page this probe sends.');
    exitCode = 66;
    return;
  }
  final Map<String, Object?> body = <String, Object?>{
    'model': model,
    'temperature': 0,
    'max_tokens': 600,
    'messages': <Object?>[
      <String, Object?>{
        'role': 'system',
        'content': 'You read handwritten exam pages. Report only the student\'s writing; '
            'ignore red or maroon examiner marks.',
      },
      <String, Object?>{
        'role': 'user',
        'content': <Object?>[
          <String, Object?>{'type': 'text', 'text': 'Give the first heading on this page and how many boxes the flow diagram has.'},
          <String, Object?>{
            'type': 'image_url',
            'image_url': <String, Object?>{'url': 'data:image/jpeg;base64,${base64Encode(page.readAsBytesSync())}'},
          },
        ],
      },
    ],
    'response_format': <String, Object?>{
      'type': 'json_schema',
      'json_schema': <String, Object?>{
        'name': 'probe',
        'schema': <String, Object?>{
          'type': 'object',
          'properties': <String, Object?>{
            'first_heading': <String, Object?>{'type': 'string'},
            'diagram_boxes': <String, Object?>{'type': 'integer'},
          },
          'required': <String>['first_heading', 'diagram_boxes'],
        },
      },
    },
  };
  final Stopwatch watch = Stopwatch()..start();
  final http.Response answer = await http.post(
    Uri.parse('${provider.base}/chat/completions'),
    headers: <String, String>{...auth, 'content-type': 'application/json'},
    body: jsonEncode(body),
  );
  stdout.writeln('\nPOST /chat/completions ($model, 1 image, json_schema) → ${answer.statusCode} in ${watch.elapsedMilliseconds} ms');
  for (final String header in <String>['retry-after', 'x-ratelimit-remaining-requests']) {
    if (answer.headers[header] != null) stdout.writeln('  $header: ${answer.headers[header]}');
  }
  if (answer.statusCode == 200) {
    final Map<String, Object?> json = jsonDecode(answer.body) as Map<String, Object?>;
    final Map<String, Object?> choice = (json['choices'] as List<Object?>).first as Map<String, Object?>;
    final Map<String, Object?> message = choice['message'] as Map<String, Object?>;
    stdout.writeln('  finish_reason: ${choice['finish_reason']}');
    stdout.writeln('  content: ${message['content']}');
    stdout.writeln('  usage: ${json['usage']}');
  } else {
    stdout.writeln('  error body (what the client must parse):\n${_short(answer.body, 1500)}');
  }
}

Map<String, String> _dotEnv() {
  final File file = File('.env');
  if (!file.existsSync()) return const <String, String>{};
  final Map<String, String> values = <String, String>{};
  for (final String raw in file.readAsLinesSync()) {
    final String line = raw.trim();
    if (line.isEmpty || line.startsWith('#') || !line.contains('=')) continue;
    final int at = line.indexOf('=');
    String value = line.substring(at + 1).trim();
    if (value.length >= 2 && (value.startsWith('"') || value.startsWith("'")) && value.endsWith(value[0])) {
      value = value.substring(1, value.length - 1);
    }
    values[line.substring(0, at).trim()] = value;
  }
  return values;
}

String _short(String text, [int max = 400]) => text.length <= max ? text : '${text.substring(0, max)}…';
