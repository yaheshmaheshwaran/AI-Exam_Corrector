import 'dart:convert';
import 'dart:io';

/// The signed-in session kept on this computer, so "Keep me signed in"
/// survives a restart.
///
/// It lives in the user's own settings folder beside the settings, readable
/// by that user alone, and is deleted on signing out. It holds the session's
/// tokens, never the password.
class SessionFile {
  const SessionFile(this.file);

  final File? file;

  /// The saved session for the server at [url], or null — none kept, kept
  /// for another server, or unreadable.
  Future<String?> read(String url) async {
    final File? file = this.file;
    if (file == null || !await file.exists()) return null;
    try {
      final Object? decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map || decoded['url'] != url) return null;
      final Object? session = decoded['session'];
      return session is String && session.isNotEmpty ? session : null;
    } on IOException {
      return null;
    } on FormatException {
      return null;
    }
  }

  /// Saves [session] (the session as JSON) for the server at [url].
  Future<void> write(String url, String session) async {
    final File? file = this.file;
    if (file == null) return;
    await file.parent.create(recursive: true);
    final File temporary = File('${file.path}.tmp');
    await temporary.writeAsString(jsonEncode(<String, String>{'url': url, 'session': session}), flush: true);
    if (!Platform.isWindows) {
      // Readable by this user only. Windows keeps the settings folder
      // private to the user already.
      try {
        await Process.run('chmod', <String>['600', temporary.path]);
      } on ProcessException {
        // The folder is the user's own; the file is still theirs.
      }
    }
    await temporary.rename(file.path);
  }

  Future<void> delete() async {
    final File? file = this.file;
    if (file == null) return;
    try {
      if (await file.exists()) await file.delete();
    } on IOException {
      // Nothing more can be done; the session has been signed out anyway.
    }
  }
}
