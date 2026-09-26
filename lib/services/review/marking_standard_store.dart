import 'dart:convert';
import 'dart:io';

import 'package:exam_corrector/domain/json_read.dart';
import 'package:exam_corrector/domain/marking_standard.dart';

/// The marking standard each question paper is marked to, and the teacher's
/// default for new papers.
///
/// Kept beside the cache, not in it: clearing the cache keeps it.
class MarkingStandardStore {
  MarkingStandardStore(this.file);

  final File file;

  Future<JsonMap> _read() async {
    try {
      if (!await file.exists()) return <String, Object?>{};
      return readMap(jsonDecode(await file.readAsString())) ?? <String, Object?>{};
    } on FormatException {
      return <String, Object?>{};
    } on FileSystemException {
      return <String, Object?>{};
    }
  }

  /// The teacher's default: the usual standard until they set one.
  Future<MarkingStandard> defaultStandard() async => switch (readMap((await _read())['default'])) {
        final JsonMap json => MarkingStandard.fromJson(json),
        null => const MarkingStandard(),
      };

  /// The standard for a paper: its own, or the default.
  Future<MarkingStandard> forPaper(String paperHash) async {
    final JsonMap saved = await _read();
    final JsonMap? paper = readMap(readMap(saved['papers'])?[paperHash]);
    if (paper != null) return MarkingStandard.fromJson(paper);
    return switch (readMap(saved['default'])) {
      final JsonMap json => MarkingStandard.fromJson(json),
      null => const MarkingStandard(),
    };
  }

  Future<void> save(String paperHash, MarkingStandard standard, {bool asDefault = false}) async {
    final JsonMap saved = await _read();
    final JsonMap papers = Map<String, Object?>.of(readMap(saved['papers']) ?? const <String, Object?>{});
    papers[paperHash] = standard.toJson();
    final JsonMap next = <String, Object?>{
      ...saved,
      'papers': papers,
      if (asDefault) 'default': standard.toJson(),
    };
    await file.parent.create(recursive: true);
    final File temporary = File('${file.path}.tmp');
    await temporary.writeAsString(jsonEncode(next));
    await temporary.rename(file.path);
  }
}
