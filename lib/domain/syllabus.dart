import 'package:exam_corrector/domain/json_read.dart';

/// One unit (or module) of a course syllabus and the topics it teaches.
class SyllabusUnit {
  const SyllabusUnit({
    required this.number,
    required this.title,
    this.topics = const <String>[],
    this.hours,
  });

  /// As printed: `I`, `3`, `Module 2`.
  final String number;
  final String title;
  final List<String> topics;

  /// Teaching hours, when printed — a sign of how deeply it is taught.
  final int? hours;

  /// How the unit is named: "Unit III — Real-Time Operating Systems".
  String get label {
    final String name = RegExp(r'^\d+$|^[IVXLC]+$').hasMatch(number) ? 'Unit $number' : number;
    return title.isEmpty ? name : '$name — $title';
  }

  JsonMap toJson() => <String, Object?>{
        'number': number,
        'title': title,
        'topics': topics,
        'hours': ?hours,
      };

  static SyllabusUnit? fromJson(JsonMap json) {
    final String? number = readString(json['number']);
    if (number == null) return null;
    return SyllabusUnit(
      number: number,
      title: readRawString(json['title']) ?? '',
      topics: readStringList(json['topics']),
      hours: readInt(json['hours']),
    );
  }
}

/// A course syllabus as the college publishes it: what the course teaches,
/// unit by unit.
///
/// It is a reference for what a course covers and how deeply — never an
/// answer key. It lists topics, not correct answers.
class Syllabus {
  const Syllabus({
    required this.id,
    required this.fileName,
    required this.courseTitle,
    this.courseCode = '',
    this.regulation = '',
    this.units = const <SyllabusUnit>[],
    this.outcomes = const <String>[],
    this.textbooks = const <String>[],
    this.text = '',
    this.addedAt,
    this.structuredBy = 'parser',
    this.notes = const <String>[],
    String? sourceId,
  }) : sourceId = sourceId ?? id;

  /// What could not be read, for the teacher: "Slides 3, 5 are pictures…".
  final List<String> notes;

  /// Unique in the library: the file's content hash, with the course's place
  /// in the file added when one file holds several courses.
  final String id;

  /// The content hash of the uploaded file, shared by every course read from
  /// it.
  final String sourceId;
  final String fileName;
  final String courseTitle;

  /// As printed: `CCS356`.
  final String courseCode;
  final String regulation;
  final List<SyllabusUnit> units;

  /// Course outcomes, `CO1: …`.
  final List<String> outcomes;
  final List<String> textbooks;

  /// Everything read from the file, kept so it can be read again.
  final String text;
  final DateTime? addedAt;

  /// `parser` or `model`: how the units were found.
  final String structuredBy;

  /// "Internet of Things (CCS356)".
  String get name => courseCode.isEmpty ? courseTitle : '$courseTitle ($courseCode)';

  Syllabus copyWith({String? courseTitle, String? courseCode}) => Syllabus(
        id: id,
        fileName: fileName,
        courseTitle: courseTitle ?? this.courseTitle,
        courseCode: courseCode ?? this.courseCode,
        regulation: regulation,
        units: units,
        outcomes: outcomes,
        textbooks: textbooks,
        text: text,
        addedAt: addedAt,
        structuredBy: structuredBy,
        notes: notes,
        sourceId: sourceId,
      );

  JsonMap toJson() => <String, Object?>{
        'id': id,
        'sourceId': sourceId,
        'fileName': fileName,
        'courseTitle': courseTitle,
        'courseCode': courseCode,
        'regulation': regulation,
        'units': <JsonMap>[for (final SyllabusUnit unit in units) unit.toJson()],
        'outcomes': outcomes,
        'textbooks': textbooks,
        'text': text,
        'addedAt': ?addedAt?.toUtc().toIso8601String(),
        'structuredBy': structuredBy,
        if (notes.isNotEmpty) 'notes': notes,
      };

  static Syllabus? fromJson(JsonMap json) {
    final String? id = readString(json['id']);
    if (id == null) return null;
    return Syllabus(
      id: id,
      fileName: readRawString(json['fileName']) ?? '',
      courseTitle: readRawString(json['courseTitle']) ?? '',
      courseCode: readRawString(json['courseCode']) ?? '',
      regulation: readRawString(json['regulation']) ?? '',
      units: readObjects(json['units'], SyllabusUnit.fromJson),
      outcomes: readStringList(json['outcomes']),
      textbooks: readStringList(json['textbooks']),
      text: readRawString(json['text']) ?? '',
      addedAt: DateTime.tryParse(readString(json['addedAt']) ?? '')?.toLocal(),
      structuredBy: readString(json['structuredBy']) ?? 'parser',
      notes: readStringList(json['notes']),
      sourceId: readString(json['sourceId']),
    );
  }
}
