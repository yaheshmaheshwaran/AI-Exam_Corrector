import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

import 'package:exam_corrector/domain/json_read.dart';

/// Stores each stage's output on disk, keyed by what produced it.
///
/// Keys are content-addressed: a document's hash plus a fingerprint of every
/// setting and upstream result the stage depended on. An unchanged file with
/// unchanged settings is never processed twice, a stage whose inputs changed
/// is recomputed automatically, and an interrupted correction resumes from the
/// first stage that has no stored result.
///
/// Layout: `<root>/docs/<document hash>/<stage>-<fingerprint>.json`, with
/// page images and crops in sibling folders.
class ArtifactStore {
  ArtifactStore(this.root, {this.enabled = true});

  final Directory root;

  /// When false nothing is read back, so every stage recomputes. Images still
  /// need somewhere to live, so they are written regardless.
  final bool enabled;

  /// A short, stable fingerprint of anything JSON-encodable.
  static String fingerprint(Object? value) =>
      sha1.convert(utf8.encode(jsonEncode(value))).toString().substring(0, 16);

  /// Hash of a file's bytes — the identity of a document.
  static Future<String> hashFile(File file) async {
    final Digest digest = await sha256.bind(file.openRead()).first;
    return digest.toString().substring(0, 24);
  }

  Directory documentDirectory(String documentHash) =>
      Directory(_join(<String>[root.path, 'docs', documentHash]));

  /// A folder for a stage's files — rendered pages, crops.
  Future<Directory> folder(String documentHash, String name) async {
    final Directory directory =
        Directory(_join(<String>[documentDirectory(documentHash).path, name]));
    await directory.create(recursive: true);
    return directory;
  }

  Future<JsonMap?> read(String documentHash, String key) async {
    if (!enabled) return null;
    final File file = _file(documentHash, key);
    try {
      if (!await file.exists()) return null;
      return readMap(jsonDecode(await file.readAsString()));
    } on FormatException {
      // A half-written or corrupted artifact is a cache miss, not a failure.
      return null;
    } on IOException {
      return null;
    }
  }

  /// Written to a temporary file and renamed, so an interruption can never
  /// leave a truncated artifact that later reads as valid.
  Future<void> write(String documentHash, String key, JsonMap value) async {
    final File file = _file(documentHash, key);
    await file.parent.create(recursive: true);
    final File temporary = File('${file.path}.tmp');
    await temporary.writeAsString(jsonEncode(value), flush: true);
    await temporary.rename(file.path);
  }

  Future<void> remove(String documentHash, String key) async {
    final File file = _file(documentHash, key);
    if (await file.exists()) await file.delete();
  }

  /// Deletes everything cached.
  Future<void> clear() async {
    if (await root.exists()) await root.delete(recursive: true);
  }

  /// Bytes used by the cache, for the Settings dialog.
  Future<int> sizeInBytes() async {
    if (!await root.exists()) return 0;
    int total = 0;
    await for (final FileSystemEntity entity in root.list(recursive: true)) {
      if (entity is File) total += await entity.length();
    }
    return total;
  }

  File _file(String documentHash, String key) => File(
        _join(<String>[documentDirectory(documentHash).path, '$key.json']),
      );

  static String _join(List<String> parts) => parts.join(Platform.pathSeparator);
}
