import 'dart:io';

/// Reads the project's `.env`, for settings the teacher has not typed into
/// the application.
///
/// Shared by [AppConfig] and the AI settings, so both find the same file and
/// read it the same way.
class DotEnv {
  const DotEnv._();

  /// The first `.env` found (see [candidates]), or nothing.
  static Future<Map<String, String>> read() async {
    for (final File file in candidates()) {
      if (!await file.exists()) continue;
      try {
        return parse(await file.readAsString());
      } on IOException {
        // An unreadable .env is not fatal: the environment or the saved
        // settings may still carry the key, and correction reports a missing
        // credential clearly.
        continue;
      }
    }
    return const <String, String>{};
  }

  /// Where a `.env` may reasonably live.
  ///
  /// A packaged application keeps it beside the executable. During development
  /// the executable sits deep inside `build/`, and the working directory of a
  /// launched app bundle is not the project — so the project root is found by
  /// walking up to the directory that holds `pubspec.yaml`. Anchoring on
  /// `pubspec.yaml` means an unrelated `.env` further up the disk is never
  /// picked up.
  static Iterable<File> candidates() sync* {
    final String separator = Platform.pathSeparator;
    final Directory executableDirectory = File(Platform.resolvedExecutable).parent;

    yield File('${executableDirectory.path}$separator.env');
    yield File('${Directory.current.path}$separator.env');

    for (final Directory start in <Directory>[Directory.current, executableDirectory]) {
      Directory directory = start;
      while (true) {
        if (File('${directory.path}${separator}pubspec.yaml').existsSync()) {
          yield File('${directory.path}$separator.env');
          break;
        }
        final Directory parent = directory.parent;
        if (parent.path == directory.path) break;
        directory = parent;
      }
    }
  }

  /// Parses `KEY=value` lines, ignoring comments and surrounding quotes.
  static Map<String, String> parse(String contents) {
    final Map<String, String> values = <String, String>{};

    for (final String rawLine in contents.split('\n')) {
      final String line = rawLine.trim();
      if (line.isEmpty || line.startsWith('#')) continue;

      final int separator = line.indexOf('=');
      if (separator <= 0) continue;

      final String key = line.substring(0, separator).trim();
      String value = line.substring(separator + 1).trim();
      if (value.length >= 2 &&
          ((value.startsWith('"') && value.endsWith('"')) || (value.startsWith("'") && value.endsWith("'")))) {
        value = value.substring(1, value.length - 1);
      }
      if (key.isNotEmpty) values[key] = value;
    }

    return values;
  }
}
