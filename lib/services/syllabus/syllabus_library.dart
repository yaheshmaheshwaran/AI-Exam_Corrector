import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:exam_corrector/core/async/cancellation.dart';
import 'package:exam_corrector/core/errors/app_exception.dart';
import 'package:exam_corrector/domain/json_read.dart';
import 'package:exam_corrector/domain/syllabus.dart';
import 'package:exam_corrector/pipeline/cache/artifact_store.dart';
import 'package:exam_corrector/services/settings_store.dart';
import 'package:exam_corrector/services/syllabus/model_syllabus_structurer.dart';
import 'package:exam_corrector/services/syllabus/syllabus_parser.dart';
import 'package:exam_corrector/services/syllabus/syllabus_reader.dart';

/// The teacher's saved syllabi, one per subject, and which one each question
/// paper is marked against.
///
/// Kept in the application's folder beside the cache, not inside it:
/// clearing the cache never loses a syllabus.
class SyllabusLibrary {
  SyllabusLibrary(
    this.root, {
    SyllabusReader reader = const SyllabusReader(),
    SyllabusParser parser = const SyllabusParser(),
    this.structurer,
  })  : _reader = reader,
        _parser = parser;

  /// The library in the application's folder, or in the temporary folder
  /// when there is none.
  factory SyllabusLibrary.standard({ModelSyllabusStructurer? structurer}) {
    final Directory base = SettingsStore.supportDirectory() ?? Directory.systemTemp;
    return SyllabusLibrary(
      Directory('${base.path}${Platform.pathSeparator}syllabi'),
      structurer: structurer,
    );
  }

  final Directory root;
  final SyllabusReader _reader;
  final SyllabusParser _parser;

  /// Reads a syllabus the parser cannot, when an API key is set.
  final ModelSyllabusStructurer? structurer;

  /// The value that records "mark this paper without a syllabus".
  static const String none = 'none';
  static const String _choicesFile = 'choices.json';

  File _entry(String id) => File('${root.path}${Platform.pathSeparator}$id.json');
  File get _choices => File('${root.path}${Platform.pathSeparator}$_choicesFile');

  /// Every saved syllabus, by course title.
  Future<List<Syllabus>> list() async {
    if (!await root.exists()) return const <Syllabus>[];
    final List<Syllabus> found = <Syllabus>[];
    await for (final FileSystemEntity entity in root.list()) {
      if (entity is! File || !entity.path.endsWith('.json')) continue;
      if (entity.path.endsWith(_choicesFile)) continue;
      final JsonMap? json = await _readJson(entity);
      if (json == null) continue;
      if (Syllabus.fromJson(json) case final Syllabus syllabus) found.add(syllabus);
    }
    found.sort((Syllabus a, Syllabus b) =>
        a.courseTitle.toLowerCase().compareTo(b.courseTitle.toLowerCase()));
    return found;
  }

  /// Reads, structures and saves the syllabus file at [path] — one entry per
  /// course it holds. Adding the same file again reads it afresh, keeping any
  /// title or code the teacher set.
  Future<List<Syllabus>> add(
    String path, {
    CancellationToken? cancel,
    void Function(String message)? onProgress,
  }) async {
    final File file = File(path);
    final String name = path.split(RegExp(r'[/\\]')).last;
    onProgress?.call('Reading the text of $name…');
    final String source = await ArtifactStore.hashFile(file);
    final SyllabusText read = await _reader.readDocument(path);
    final String text = read.text;
    final List<PictureSlide> pictures = read.pictureSlides;
    cancel?.throwIfCancelled();

    onProgress?.call('Finding the courses and units in $name…');
    List<ParsedSyllabus> courses = _parser.parseAll(text);
    String by = 'parser';
    final List<String> notes = <String>[];
    final ModelSyllabusStructurer? model = structurer;
    final bool modelReady = model != null && model.isAvailable;
    final bool textGaveUnits = courses.any((ParsedSyllabus c) => c.hasUnits);
    final String slideList = pictures.map((PictureSlide p) => p.slide).join(', ');

    // The AI reads what the file's own text could not: an unusual layout, or
    // slides that are pictures. A deck of several courses keeps the text's
    // reading, since one request gives back a single course.
    final bool readPictures = pictures.isNotEmpty && courses.length <= 1;
    if (modelReady && (!textGaveUnits || readPictures)) {
      onProgress?.call(pictures.isNotEmpty
          ? '${pictures.length == 1 ? 'Slide $slideList is a picture' : 'Slides $slideList are pictures'}'
              ' — asking the AI to read ${pictures.length == 1 ? 'it' : 'them'}. This can take a minute.'
          : '$name has an unusual layout — asking the AI to read it. This can take a minute.');
      final ParsedSyllabus read = await model.structure(
        text,
        images: <({int slide, Uint8List bytes, String mimeType})>[
          for (final PictureSlide p in pictures) (slide: p.slide, bytes: p.bytes, mimeType: p.mimeType),
        ],
        cancel: cancel,
        onProgress: onProgress,
      );
      // The model's reading is kept only when it found at least as much.
      if (read.hasUnits &&
          (!textGaveUnits || read.units.length >= courses.first.units.length)) {
        courses = <ParsedSyllabus>[read];
        by = 'model';
      }
      if (pictures.length > ModelSyllabusStructurer.maxImages) {
        notes.add('Only the first ${ModelSyllabusStructurer.maxImages} of '
            '${pictures.length} picture slides were read.');
      }
    } else if (pictures.isNotEmpty) {
      notes.add('${pictures.length == 1 ? 'Slide $slideList is a picture' : 'Slides $slideList are pictures'}'
          ' and ${pictures.length == 1 ? "wasn't" : "weren't"} read'
          '${modelReady ? ' — the file holds several courses' : ' — add an API key in Settings and add the file again to read ${pictures.length == 1 ? 'it' : 'them'}'}.');
    }
    cancel?.throwIfCancelled();
    courses = courses.where((ParsedSyllabus c) => c.hasUnits).toList();
    if (courses.isEmpty) {
      throw SyllabusException(
        pictures.isNotEmpty && !modelReady
            ? 'The syllabus in this file is in pictures (slides $slideList), which '
                'need the AI to read. Add an API key in Settings, then add the file again.'
            : 'No units or topics could be found in this file. Check that it is the '
                'course syllabus${modelReady ? '' : ', or add an API key in Settings so an unusual layout can be read by the model'}.',
      );
    }

    final String fileName = path.split(RegExp(r'[/\\]')).last;
    final String stem = fileName.replaceAll(RegExp(r'\.[^.]+$'), '');
    final List<Syllabus> previous =
        (await list()).where((Syllabus s) => s.sourceId == source).toList();
    Syllabus? before(String id) => previous.where((Syllabus s) => s.id == id).firstOrNull;

    final List<Syllabus> saved = <Syllabus>[];
    for (int k = 0; k < courses.length; k++) {
      final ParsedSyllabus course = courses[k];
      final String id = courses.length == 1 ? source : '$source-${k + 1}';
      final Syllabus? old = before(id);
      final String title = course.courseTitle.isNotEmpty
          ? course.courseTitle
          : courses.length == 1
              ? stem
              : '$stem — course ${k + 1}';
      saved.add(Syllabus(
        id: id,
        sourceId: source,
        fileName: fileName,
        courseTitle: old?.courseTitle ?? title,
        courseCode: old?.courseCode ?? course.courseCode,
        regulation: course.regulation,
        units: course.units,
        outcomes: course.outcomes,
        textbooks: course.textbooks,
        // The whole file is kept once, with its first course.
        text: k == 0 ? text : '',
        addedAt: old?.addedAt ?? DateTime.now(),
        structuredBy: by,
        notes: notes,
      ));
    }

    // A course the file no longer holds is dropped.
    for (final Syllabus stale in previous) {
      if (!saved.any((Syllabus s) => s.id == stale.id)) await remove(stale.id);
    }
    for (final Syllabus syllabus in saved) {
      await _write(_entry(syllabus.id), syllabus.toJson());
    }
    return saved;
  }

  /// Removes every course read from one uploaded file.
  Future<void> removeSource(String sourceId) async {
    for (final Syllabus syllabus in await list()) {
      if (syllabus.sourceId == sourceId) await remove(syllabus.id);
    }
  }

  Future<Syllabus?> byId(String id) async {
    final JsonMap? json = await _readJson(_entry(id));
    return json == null ? null : Syllabus.fromJson(json);
  }

  Future<void> remove(String id) async {
    final File file = _entry(id);
    if (await file.exists()) await file.delete();
    // A paper chosen to be marked against it goes back to matching.
    final Map<String, String> choices = await _readChoices();
    choices.removeWhere((String paper, String chosen) => chosen == id);
    await _write(_choices, choices);
  }

  /// Corrects what matching relies on.
  Future<Syllabus?> update(String id, {String? courseTitle, String? courseCode}) async {
    final Syllabus? syllabus = await byId(id);
    if (syllabus == null) return null;
    final Syllabus updated = syllabus.copyWith(
      courseTitle: courseTitle?.trim(),
      courseCode: courseCode?.trim().toUpperCase(),
    );
    await _write(_entry(id), updated.toJson());
    return updated;
  }

  /// The teacher's choice for a question paper: a syllabus ID, [none], or
  /// null to match automatically.
  Future<String?> choiceFor(String paperHash) async => (await _readChoices())[paperHash];

  Future<void> setChoice(String paperHash, String? choice) async {
    final Map<String, String> choices = await _readChoices();
    if (choice == null) {
      choices.remove(paperHash);
    } else {
      choices[paperHash] = choice;
    }
    await _write(_choices, choices);
  }

  Future<Map<String, String>> _readChoices() async => <String, String>{
        for (final MapEntry<String, Object?> entry
            in (await _readJson(_choices) ?? const <String, Object?>{}).entries)
          if (readString(entry.value) case final String value) entry.key: value,
      };

  static Future<JsonMap?> _readJson(File file) async {
    try {
      if (!await file.exists()) return null;
      return readMap(jsonDecode(await file.readAsString()));
    } on FormatException {
      return null;
    } on FileSystemException {
      return null;
    }
  }

  /// Written whole to a temporary file and moved into place, so a crash
  /// never leaves half a syllabus.
  Future<void> _write(File file, Object json) async {
    await root.create(recursive: true);
    final File temporary = File('${file.path}.tmp');
    await temporary.writeAsString(jsonEncode(json));
    await temporary.rename(file.path);
  }
}
