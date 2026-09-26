import 'package:exam_corrector/domain/syllabus.dart';

/// What the parser could read from a syllabus's text.
class ParsedSyllabus {
  const ParsedSyllabus({
    this.courseTitle = '',
    this.courseCode = '',
    this.regulation = '',
    this.units = const <SyllabusUnit>[],
    this.outcomes = const <String>[],
    this.textbooks = const <String>[],
  });

  final String courseTitle;
  final String courseCode;
  final String regulation;
  final List<SyllabusUnit> units;
  final List<String> outcomes;
  final List<String> textbooks;

  bool get hasUnits => units.isNotEmpty;
}

/// Reads a syllabus's structure from its text, deterministically.
///
/// Built for the layout universities actually publish: a course code and
/// title, `UNIT I  TITLE  9` headings with the unit's topics run together
/// beneath, separated by dashes, then course outcomes (`CO1: …`) and books.
/// `Unit 1:`, `Module 2 -` and headings without hours are read too. Free and
/// repeatable, so it is tried before any model.
class SyllabusParser {
  const SyllabusParser();

  static final RegExp _unitHeading = RegExp(
    r'^(unit|module)\s*[-–—:.]?\s*([ivx]+|\d{1,2})(?![a-z0-9])\s*[-–—:.]?\s*(.*?)\s*(?:[(\[]?\s*(\d{1,2})\s*(?:hours?|hrs?\.?|periods?|l)?\s*[)\]]?)?\s*$',
    caseSensitive: false,
  );
  static final RegExp _codeLine = RegExp(
    r'^([A-Z]{2,5}\s?\d{3,4}[A-Z]?)\s{2,}(.+?)(?:\s+L\s*T\s*P\s*C.*|\s+\d\s+\d\s+\d\s+\d\s*)?$',
  );
  static final RegExp _labelledCode = RegExp(
    r'(?:course|subject|paper)\s*code\s*[:\-–]?\s*([A-Z]{2,5}\s?\d{3,4}[A-Z]?)',
    caseSensitive: false,
  );
  static final RegExp _labelledTitle = RegExp(
    r'^(?:course|subject|paper)\s*(?:title|name)\s*[:\-–]\s*(.+)$',
    caseSensitive: false,
  );
  static final RegExp _regulation = RegExp(
    r'\bregulations?\s*[:\-–]?\s*(R?\s?20\d\d)\b|\b(R20\d\d)\b',
    caseSensitive: false,
  );
  static final RegExp _outcome = RegExp(r'^CO\s?(\d{1,2})\s*[:.\-–)]?\s*(.+)$');
  static final RegExp _marker = RegExp(r'^---\s*(?:Page|Slide)\s+\d+\s*---$');

  /// A table's heading row: every cell a column name.
  static final RegExp _headerCell = RegExp(
    r'^(?:s\.?\s*no\.?|sl\.?\s*no\.?|units?|modules?|(?:unit|module)\s*(?:no\.?|title|name)|title|topics?|contents?|'
    r'course\s*contents?|syllabus|description|details|hours?|hrs\.?|periods?|no\.?\s*of\s*(?:hours|periods)|'
    r'[ltpc]|co|co\s*mapping|bt\s*levels?|credits?)$',
    caseSensitive: false,
  );

  /// A cell holding a unit's number: `UNIT I`, `Unit 1`, `Module 2`, `III`.
  static final RegExp _unitCell = RegExp(
    r'^(?:(unit|module)\s*[-–—:.]?\s*)?([ivx]+|\d{1,2})\s*[.:)]?$',
    caseSensitive: false,
  );

  /// A table row that starts a unit: a cell with its number, then its title,
  /// its topics and perhaps its hours in cells of their own.
  static ({String number, String title, int? hours, String topics})? _tableUnit(List<String> cells) {
    // A cell that says "Unit" or "Module" wins over a bare number, which in
    // front of it is only the table's serial number.
    int? named;
    for (int i = 0; i < cells.length && i < 3; i++) {
      final RegExpMatch? m = _unitCell.firstMatch(cells[i]) ?? _unitHeading.firstMatch(cells[i]);
      if (m != null && m.group(1) != null) {
        named = i;
        break;
      }
    }
    final List<int> candidates = named != null ? <int>[named] : <int>[0, 1];
    for (final int i in candidates) {
      if (i >= cells.length) continue;
      final String cell = cells[i];
      final List<String> rest = <String>[
        for (int j = 0; j < cells.length; j++)
          if (j != i && !(named != null && j < i && RegExp(r'^\d{1,2}\.?$').hasMatch(cells[j]))) cells[j],
      ];

      final RegExpMatch? bare = _unitCell.firstMatch(cell);
      final RegExpMatch? heading = bare == null ? _unitHeading.firstMatch(cell) : null;
      if (bare == null && heading == null) continue;
      final String? kind = (bare ?? heading)!.group(1)?.toLowerCase();
      // A bare "3" is a unit only with a title or topics beside it.
      if (kind == null && rest.where((String c) => RegExp('[A-Za-z]{3}').hasMatch(c)).isEmpty) {
        continue;
      }
      final String number = (bare ?? heading)!.group(2)!.toUpperCase();

      int? hours = heading == null ? null : int.tryParse(heading.group(4) ?? '');
      final List<String> texts = <String>[];
      for (final String c in rest) {
        final RegExpMatch? h = RegExp(r'^(\d{1,2})\s*(?:hours?|hrs?\.?|periods?)?$', caseSensitive: false).firstMatch(c);
        if (h != null) {
          hours = int.parse(h.group(1)!);
        } else if (RegExp('[A-Za-z]').hasMatch(c)) {
          texts.add(c);
        }
      }
      if (texts.isEmpty && heading == null) continue;

      String title = heading == null ? '' : _tidyTitle(heading.group(3) ?? '');
      String topics;
      if (title.isNotEmpty) {
        topics = texts.join('  ');
      } else if (texts.length == 1) {
        // "Title: topic, topic" in a single cell.
        final String only = texts.single;
        final int colon = only.indexOf(':');
        if (colon > 0 && colon < 80) {
          title = _tidyTitle(only.substring(0, colon));
          topics = only.substring(colon + 1).trim();
        } else {
          topics = only;
        }
      } else {
        topics = texts.reduce((String a, String b) => b.length > a.length ? b : a);
        title = _tidyTitle(texts.firstWhere((String t) => t != topics));
      }
      return (
        number: kind == 'module' ? 'Module $number' : number,
        title: title,
        hours: hours,
        topics: topics,
      );
    }
    return null;
  }

  /// A course code standing on its own line, as PDF text often has it when
  /// the code and title sit in separate columns.
  static final RegExp _codeOnly = RegExp(r'^([A-Z]{2,5}\s?\d{3,4}[A-Z]?)$');

  /// The credit columns printed beside a course title: `L T P C`, `3 0 0 3`.
  static final RegExp _credits = RegExp(r'^(?:L\s*T\s*P\s*C|\d\s+\d\s+\d\s+\d(?:\.\d)?)$');
  static final RegExp _total = RegExp(r'^total\s*[:\-]?\s*\d+\s*(periods|hours)', caseSensitive: false);

  static const Map<String, _Part> _headings = <String, _Part>{
    'course objectives': _Part.objectives,
    'objectives': _Part.objectives,
    'course outcomes': _Part.outcomes,
    'outcomes': _Part.outcomes,
    'text books': _Part.books,
    'textbooks': _Part.books,
    'text book': _Part.books,
    'references': _Part.references,
    'reference books': _Part.references,
    'list of experiments': _Part.other,
    'practical exercises': _Part.other,
    'lab exercises': _Part.other,
  };

  /// Every course in [text]. A college often publishes one PDF for a whole
  /// programme — every course of the regulation, one after another — and each
  /// becomes a syllabus of its own. A new course starts at a course code line
  /// that comes after units have been read; a file with one course gives one.
  List<ParsedSyllabus> parseAll(String text) {
    final List<String> lines = text.split('\n');
    final List<int> starts = <int>[0];
    bool sawUnit = false;
    for (int i = 0; i < lines.length; i++) {
      final String line = lines[i].trim();
      final String flat = line.replaceAll(RegExp(r'\s+'), ' ');
      final bool courseStart = _codeOnly.hasMatch(flat) ||
          _codeLine.hasMatch(line) ||
          (_labelledCode.hasMatch(flat) && flat.length < 60);
      if (courseStart && sawUnit) {
        starts.add(i);
        sawUnit = false;
      }
      if (_unitHeading.hasMatch(flat)) sawUnit = true;
    }
    if (starts.length == 1) return <ParsedSyllabus>[parse(text)];

    // The regulation is usually printed once, at the front of the book.
    final RegExpMatch? regulation = _regulation.firstMatch(text.replaceAll(RegExp(r'\s+'), ' '));
    String shared = regulation == null
        ? ''
        : (regulation.group(1) ?? regulation.group(2))!.replaceAll(' ', '').toUpperCase();
    if (shared.isNotEmpty && !shared.startsWith('R')) shared = 'R$shared';

    final List<ParsedSyllabus> courses = <ParsedSyllabus>[];
    for (int k = 0; k < starts.length; k++) {
      final int end = k + 1 < starts.length ? starts[k + 1] : lines.length;
      final ParsedSyllabus course = parse(lines.sublist(starts[k], end).join('\n'));
      if (!course.hasUnits) continue;
      courses.add(ParsedSyllabus(
        courseTitle: course.courseTitle,
        courseCode: course.courseCode,
        regulation: course.regulation.isEmpty ? shared : course.regulation,
        units: course.units,
        outcomes: course.outcomes,
        textbooks: course.textbooks,
      ));
    }
    return courses.isEmpty ? <ParsedSyllabus>[parse(text)] : courses;
  }

  ParsedSyllabus parse(String text) {
    String code = '';
    String title = '';
    String regulation = '';
    final List<SyllabusUnit> units = <SyllabusUnit>[];
    final List<String> outcomes = <String>[];
    final List<String> books = <String>[];
    final List<String> references = <String>[];

    _Part part = _Part.front;
    ({String number, String title, int? hours})? unit;
    final StringBuffer body = StringBuffer();

    void closeUnit() {
      final ({String number, String title, int? hours})? open = unit;
      if (open == null) return;
      units.add(SyllabusUnit(
        number: open.number,
        title: open.title,
        hours: open.hours,
        topics: _topics(body.toString()),
      ));
      unit = null;
      body.clear();
    }

    bool titleNext = false; // A code stood alone; the title is the next line.
    bool hoursNext = false; // A unit heading without its hours.

    for (final String raw in text.split('\n')) {
      final String line = raw.trim();
      if (line.isEmpty) continue;
      if (_marker.hasMatch(line)) continue;

      // A table row from PowerPoint or Word: its cells, separated by tabs.
      if (line.contains('\t')) {
        final List<String> cells = <String>[
          for (final String cell in line.split('\t'))
            if (cell.trim().replaceAll(RegExp(r'\s+'), ' ') case final String c when c.isNotEmpty) c,
        ];
        if (cells.length >= 2) {
          final String label = cells.first.toLowerCase();
          if (code.isEmpty && RegExp(r'^(?:course|subject|paper)\s*(?:code|no\.?)$').hasMatch(label)) {
            code = cells[1].replaceAll(' ', '');
            continue;
          }
          if (title.isEmpty && RegExp(r'^(?:course|subject|paper)\s*(?:title|name)$').hasMatch(label)) {
            title = _tidyTitle(cells[1]);
            continue;
          }
        }
        if (cells.isNotEmpty && cells.every(_headerCell.hasMatch)) continue;
        final ({String number, String title, int? hours, String topics})? row = _tableUnit(cells);
        if (row != null && part != _Part.books && part != _Part.references) {
          closeUnit();
          part = _Part.units;
          unit = (number: row.number, title: row.title, hours: row.hours);
          body.write(' ${row.topics}');
          hoursNext = false;
          continue;
        }
        if (part == _Part.units && unit != null && !_outcome.hasMatch(cells.first)) {
          // The unit's topics, carried on into another row.
          body.write('  ${cells.where((String c) => !RegExp(r'^\d{1,2}$').hasMatch(c)).join('  ')}');
          continue;
        }
      }
      final String flat = line.replaceAll(RegExp(r'\s+'), ' ');

      if (_credits.hasMatch(flat)) continue;
      // The hours of the unit just opened, printed in a column of their own.
      if (hoursNext) {
        hoursNext = false;
        final RegExpMatch? hours = RegExp(r'^(\d{1,2})\s*(?:hours?|hrs?\.?|periods?)?$', caseSensitive: false)
            .firstMatch(flat);
        if (hours != null && unit != null) {
          final ({String number, String title, int? hours}) open = unit!;
          unit = (number: open.number, title: open.title, hours: int.parse(hours.group(1)!));
          continue;
        }
      }
      if (titleNext) {
        titleNext = false;
        if (title.isEmpty && !_unitHeading.hasMatch(flat) && RegExp(r'[A-Za-z]{3}').hasMatch(flat)) {
          title = _tidyTitle(flat);
          continue;
        }
      }
      if (code.isEmpty && part == _Part.front && _codeOnly.hasMatch(flat)) {
        code = flat.replaceAll(' ', '');
        titleNext = true;
        continue;
      }

      if (regulation.isEmpty) {
        final RegExpMatch? match = _regulation.firstMatch(flat);
        if (match != null) {
          regulation = (match.group(1) ?? match.group(2))!.replaceAll(' ', '').toUpperCase();
          if (!regulation.startsWith('R')) regulation = 'R$regulation';
        }
      }
      if (code.isEmpty) {
        final RegExpMatch? labelled = _labelledCode.firstMatch(flat);
        final RegExpMatch? codeLine = _codeLine.firstMatch(line);
        if (labelled != null) {
          code = labelled.group(1)!.replaceAll(' ', '');
        } else if (codeLine != null && part == _Part.front) {
          code = codeLine.group(1)!.replaceAll(' ', '');
          if (title.isEmpty) title = _tidyTitle(codeLine.group(2)!);
          continue;
        }
      }
      if (title.isEmpty) {
        final RegExpMatch? labelled = _labelledTitle.firstMatch(flat);
        if (labelled != null) {
          title = _tidyTitle(labelled.group(1)!);
          continue;
        }
      }

      final _Part? heading =
          _headings[flat.toLowerCase().replaceAll(RegExp(r'[:.\s]+$'), '')];
      if (heading != null) {
        closeUnit();
        part = heading;
        continue;
      }

      final RegExpMatch? unitHeading = _unitHeading.firstMatch(flat);
      if (unitHeading != null && part != _Part.books && part != _Part.references) {
        closeUnit();
        part = _Part.units;
        final String kind = unitHeading.group(1)!.toLowerCase();
        final String number = unitHeading.group(2)!.toUpperCase();
        unit = (
          number: kind == 'module' ? 'Module $number' : number,
          title: _tidyTitle(unitHeading.group(3) ?? ''),
          hours: int.tryParse(unitHeading.group(4) ?? ''),
        );
        hoursNext = unit!.hours == null;
        continue;
      }
      if (_total.hasMatch(flat)) {
        closeUnit();
        part = _Part.other;
        continue;
      }

      final RegExpMatch? outcome = _outcome.firstMatch(flat);
      if (outcome != null) {
        closeUnit();
        part = _Part.outcomes;
        outcomes.add('CO${outcome.group(1)}: ${outcome.group(2)!.trim()}');
        continue;
      }

      switch (part) {
        case _Part.units:
          if (unit != null) body.write(' $line');
        case _Part.books:
          books.add(flat.replaceFirst(RegExp(r'^\d+[.)]\s*'), ''));
        case _Part.references:
          references.add(flat.replaceFirst(RegExp(r'^\d+[.)]\s*'), ''));
        case _Part.front || _Part.objectives || _Part.outcomes || _Part.other:
          break;
      }
    }
    closeUnit();

    return ParsedSyllabus(
      courseTitle: title,
      courseCode: code,
      regulation: regulation,
      units: units,
      outcomes: outcomes,
      textbooks: books.isNotEmpty ? books : references,
    );
  }

  /// A unit's run-together text as its topics: split on the dashes,
  /// semicolons and full stops syllabi separate them with, but not inside
  /// "Wi-Fi" or "6LoWPAN".
  static List<String> _topics(String body) {
    final String text = body.trim();
    if (text.isEmpty) return const <String>[];
    // PDF text often loses the dashes between topics, leaving a wide gap
    // where each was: then the gaps separate them.
    final bool dashes = RegExp(r'\s[–—-]\s|[–—]').hasMatch(text);
    final RegExp separator = dashes
        ? RegExp(r'\s[–—-]\s|[;–—]|\.\s+|\.$')
        : RegExp(r'\s{2,}|;|\.\s+|\.$');
    final List<String> topics = <String>[
      for (final String piece in text.split(separator))
        if (piece.trim().replaceAll(RegExp(r'\s+'), ' ') case final String topic
            when topic.length >= 3)
          topic,
    ];
    // A table cell often lists its topics with commas alone: one long run
    // of them is split there too.
    if (topics.length == 1 && topics.single.length > 100 && topics.single.contains(',')) {
      return <String>[
        for (final String piece in topics.single.split(','))
          if (piece.trim() case final String topic when topic.length >= 3) topic,
      ];
    }
    return topics;
  }

  /// Capitals as printed become readable, but acronyms stay: "INTRODUCTION TO
  /// IoT" → "Introduction to IoT".
  static String _tidyTitle(String title) {
    final String flat = title.replaceAll(RegExp(r'\s+'), ' ').trim();
    const Set<String> small = <String>{'and', 'of', 'to', 'in', 'for', 'on', 'the', 'a', 'an', 'with', 'its'};
    final List<String> words = flat.split(' ');
    return <String>[
      for (int i = 0; i < words.length; i++)
        () {
          final String word = words[i];
          if (word != word.toUpperCase() || word.length <= 1) return word;
          // All capitals: an acronym if short and unlike a word, else a word.
          final String lower = word.toLowerCase();
          if (word.length <= 4 && !small.contains(lower) && !RegExp(r'^[A-Z]+$').hasMatch(word)) {
            return word;
          }
          if (i > 0 && small.contains(lower)) return lower;
          return '${word[0]}${lower.substring(1)}';
        }(),
    ].join(' ');
  }
}

enum _Part { front, objectives, units, outcomes, books, references, other }
