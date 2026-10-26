import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import 'package:exam_corrector/ai/ai_settings.dart';
import 'package:exam_corrector/ai/model_roles.dart';
import 'package:exam_corrector/ai/providers.dart';
import 'package:exam_corrector/core/async/observable.dart';

/// Whether a model server answered the last time it was asked.
enum ServerState { unknown, up, down }

/// What is known about one server.
class ServerStatus {
  const ServerStatus({this.state = ServerState.unknown, this.reason = '', this.since, this.lastProbe});

  final ServerState state;

  /// Why it is down, in the teacher's words; empty when it is not.
  final String reason;

  /// When it went down.
  final DateTime? since;

  /// When it was last checked on purpose.
  final DateTime? lastProbe;

  bool get isDown => state == ServerState.down;
}

/// Remembers which of our own servers are unreachable — a Kaggle notebook
/// that stopped, a closed tunnel, Ollama not running — so a run stops asking
/// a dead one on every request, and checks whether it has come back before
/// each script.
///
/// Nothing here is saved: a server's state only means something while the
/// application runs.
class ProviderHealth with Observable {
  ProviderHealth({http.Client? client, DateTime Function()? clock, this.probeEvery = const Duration(minutes: 1)})
      : _client = client,
        _now = clock ?? DateTime.now;

  final http.Client? _client;
  final DateTime Function() _now;

  /// How long a server stays skipped before it is checked again.
  final Duration probeEvery;

  /// How long a check may take.
  static const Duration probeTimeout = Duration(seconds: 8);

  final Map<String, ServerStatus> _status = <String, ServerStatus>{};

  /// The state of the provider [id] names.
  ServerStatus statusOf(String id) => _status[id] ?? const ServerStatus();

  bool isDown(String id) => statusOf(id).isDown;

  /// [id] could not be reached; [reason] says why.
  void markDown(String id, String reason) {
    final ServerStatus old = statusOf(id);
    _status[id] = ServerStatus(
      state: ServerState.down,
      reason: reason,
      since: old.isDown ? old.since : _now(),
      lastProbe: old.lastProbe ?? _now(),
    );
    notifyListeners();
  }

  /// [id] answered.
  void markUp(String id) {
    if (statusOf(id).state == ServerState.up) return;
    _status[id] = ServerStatus(state: ServerState.up, lastProbe: statusOf(id).lastProbe);
    notifyListeners();
  }

  /// Checks each of our own servers named by a role that is down and has not
  /// been checked for [probeEvery]. Called before each script, so a server
  /// that has come back is used again from the next script on.
  Future<void> recheck(AiSettings settings) async {
    final Set<String> checked = <String>{};
    for (final ModelRole role in ModelRole.values) {
      for (final String model in settings.roles.chain(role)) {
        final ModelProvider? provider = settings.providers.of(model);
        if (provider == null || !provider.selfHosted || !provider.isConfigured || !checked.add(provider.id)) continue;
        final ServerStatus status = statusOf(provider.id);
        if (!status.isDown) continue;
        final DateTime? last = status.lastProbe;
        if (last != null && _now().difference(last) < probeEvery) continue;
        await probe(provider);
      }
    }
  }

  /// Asks [provider] for its model list; marks it up or down by the answer.
  Future<bool> probe(ModelProvider provider) async {
    final ({bool ok, String reason}) result = await reach(provider, client: _client);
    final ServerStatus old = statusOf(provider.id);
    _status[provider.id] = result.ok
        ? ServerStatus(state: ServerState.up, lastProbe: _now())
        : ServerStatus(state: ServerState.down, reason: result.reason, since: old.since ?? _now(), lastProbe: _now());
    notifyListeners();
    return result.ok;
  }

  /// Whether [provider] answers at all: its model list.
  static Future<({bool ok, String reason})> reach(ModelProvider provider, {http.Client? client}) async {
    final http.Client http_ = client ?? http.Client();
    try {
      final http.Response response = await http_.get(Uri.parse('${provider.baseUrl}/models'), headers: <String, String>{
        if (provider.apiKey?.isNotEmpty ?? false) 'authorization': 'Bearer ${provider.apiKey}',
      }).timeout(probeTimeout);
      if (response.statusCode == 200) return (ok: true, reason: '');
      return (ok: false, reason: describeStatus(response.statusCode, response.body));
    } on SocketException {
      return (ok: false, reason: 'not reachable');
    } on TimeoutException {
      return (ok: false, reason: 'did not answer within ${probeTimeout.inSeconds} s');
    } on http.ClientException {
      return (ok: false, reason: 'the connection failed');
    } finally {
      if (client == null) http_.close();
    }
  }

  /// A short, readable reason for an HTTP status — never a whole error page.
  static String describeStatus(int status, String body) {
    if (status >= 520 && status <= 530) {
      return 'the tunnel is not connected (Cloudflare $status) — the notebook or its tunnel has stopped';
    }
    if (status == 401 || status == 403) return 'the key was rejected ($status)';
    final String text = body.trimLeft();
    if (text.startsWith('<')) return 'it answered with an error page ($status)';
    try {
      final Object? decoded = jsonDecode(text);
      final Object? first = decoded is List && decoded.isNotEmpty ? decoded.first : decoded;
      if (first is Map<String, dynamic>) {
        final Object? error = first['error'];
        final Object? message = error is Map<String, dynamic> ? error['message'] : error;
        if (message is String && message.isNotEmpty) return '$message ($status)';
      }
    } on FormatException {
      // Plain text, below.
    }
    final String short = text.length > 120 ? '${text.substring(0, 120)}…' : text;
    return short.isEmpty ? 'error $status' : '$short ($status)';
  }

  /// Every server known to be down, as `label: reason` lines.
  List<String> downDescriptions(AiSettings settings) => <String>[
        for (final ModelProvider provider in settings.providers.all)
          if (isDown(provider.id)) '${provider.label}: ${statusOf(provider.id).reason}',
      ];
}
