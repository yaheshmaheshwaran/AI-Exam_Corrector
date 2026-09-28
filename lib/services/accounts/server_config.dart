import 'dart:io';

import 'package:exam_corrector/core/errors/app_exception.dart';
import 'package:exam_corrector/services/settings_store.dart';

/// Where the college server is: a Supabase project's URL and its public
/// (anon) key.
///
/// The key is public by design — it lets the app ask; what anyone may see or
/// change is decided by the rules on the server. The private service key
/// never belongs here.
class ServerConfig {
  const ServerConfig({required this.url, required this.anonKey});

  final String url;
  final String anonKey;

  /// The server's host, for showing the teacher which server this is.
  String get host => Uri.tryParse(url)?.host ?? url;

  /// The configured server, or null when there is none: the environment
  /// first, then this computer's settings, then a college's own build
  /// (`--dart-define=SUPABASE_URL=… --dart-define=SUPABASE_ANON_KEY=…`).
  static Future<ServerConfig?> load({
    SettingsStore settings = const SettingsStore(),
    Map<String, String>? environment,
  }) async {
    final Map<String, String> env = environment ?? Platform.environment;
    final Map<String, String> saved = await settings.read();
    String? pick(String field, String defined) {
      for (final String? value in <String?>[env[field], saved[field], defined]) {
        if (value != null && value.trim().isNotEmpty) return value.trim();
      }
      return null;
    }

    final String? url = pick(SettingsStore.supabaseUrlField, const String.fromEnvironment('SUPABASE_URL'));
    final String? key = pick(SettingsStore.supabaseAnonKeyField, const String.fromEnvironment('SUPABASE_ANON_KEY'));
    if (url == null || key == null) return null;
    try {
      return validated(url: url, anonKey: key);
    } on AccountException {
      return null;
    }
  }

  /// A server as typed in: an https address and a key, tidied.
  static ServerConfig validated({required String url, required String anonKey}) {
    String address = url.trim();
    while (address.endsWith('/')) {
      address = address.substring(0, address.length - 1);
    }
    final Uri? uri = Uri.tryParse(address);
    if (uri == null || !uri.hasAuthority || (uri.scheme != 'https' && !_local(uri))) {
      throw const AccountException(
        'The server address should start with https:// — copy the Project URL from your Supabase project settings.',
      );
    }
    final String key = anonKey.trim();
    if (key.length < 20 || key.contains(' ')) {
      throw const AccountException('That does not look like a key — copy the anon (public) key from the same page.');
    }
    return ServerConfig(url: address, anonKey: key);
  }

  /// A server on this computer, for trying the setup out: plain http is
  /// allowed only there.
  static bool _local(Uri uri) => uri.scheme == 'http' && (uri.host == 'localhost' || uri.host == '127.0.0.1');

  @override
  bool operator ==(Object other) => other is ServerConfig && other.url == url && other.anonKey == anonKey;

  @override
  int get hashCode => Object.hash(url, anonKey);
}
