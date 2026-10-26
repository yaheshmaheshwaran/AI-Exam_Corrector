import 'package:exam_corrector/domain/syllabus.dart';

/// The words that carry meaning in a piece of text, normalised so that
/// "Protocols" in a question meets "protocol" in a syllabus.
Set<String> syllabusKeywords(String text) => <String>{
      for (final String raw in text.toLowerCase().split(RegExp(r'[^a-z0-9]+')))
        if (raw.length >= 3 && !_stopwords.contains(raw) && !RegExp(r'^\d+$').hasMatch(raw))
          _stem(raw),
    };

String _stem(String word) {
  if (word.length > 5 && word.endsWith('ing')) return word.substring(0, word.length - 3);
  if (word.length > 4 && word.endsWith('ies')) return '${word.substring(0, word.length - 3)}y';
  if (word.length > 4 && word.endsWith('es') && !word.endsWith('ses')) {
    return word.substring(0, word.length - 2);
  }
  if (word.length > 3 && word.endsWith('s') && !word.endsWith('ss')) {
    return word.substring(0, word.length - 1);
  }
  return word;
}

const Set<String> _stopwords = <String>{
  'the', 'and', 'for', 'with', 'that', 'this', 'from', 'are', 'was', 'were', 'which', 'what',
  'how', 'why', 'when', 'where', 'who', 'its', 'into', 'your', 'you', 'can', 'will', 'has', 'have',
  'not', 'but', 'all', 'any', 'each', 'one', 'two', 'three', 'four', 'five', 'marks', 'mark',
  'explain', 'describe', 'discuss', 'define', 'write', 'short', 'note', 'notes', 'brief', 'briefly',
  'detail', 'list', 'state', 'give', 'name', 'draw', 'neat', 'diagram', 'suitable', 'example',
  'examples', 'compare', 'differentiate', 'between', 'answer', 'question', 'following', 'using',
  'used', 'use', 'also', 'mainly', 'primarily', 'generally', 'does', 'require', 'about', 'their',
  'there', 'these', 'those', 'such', 'than', 'then', 'them', 'they', 'unit', 'module',
};

/// The part of a syllabus a question falls under, as the marker is shown it.
class SyllabusContext {
  const SyllabusContext({this.label = '', this.text = '', this.focus = ''});

  /// "Unit III — IoT Communication and Connectivity". Empty when no unit
  /// matched with confidence.
  final String label;

  /// The unit and its topics, most relevant first.
  final String text;

  /// Only the topics the question itself touches — what a good answer to it
  /// covers. Empty when it touches none by name.
  final String focus;

  bool get isEmpty => text.isEmpty;

  static const SyllabusContext none = SyllabusContext();
}

/// Finds, for each question, the unit of the syllabus it belongs to — locally,
/// by the words they share, spending no requests.
///
/// It would rather give no unit than a wrong one: a question that shares too
/// little with every unit gets the course alone, and the marker falls back on
/// its own knowledge of the subject.
class SyllabusIndex {
  SyllabusIndex(this.syllabus)
      : _units = <_IndexedUnit>[
          for (final SyllabusUnit unit in syllabus.units)
            _IndexedUnit(
              unit,
              syllabusKeywords(unit.title),
              <Set<String>>[for (final String topic in unit.topics) syllabusKeywords(topic)],
            ),
        ];

  final Syllabus syllabus;
  final List<_IndexedUnit> _units;

  /// The most the marker is shown of a unit.
  static const int maxCharacters = 700;

  /// One line for the whole course, shown once per request.
  String get courseHeader {
    final List<String> parts = <String>[
      syllabus.name,
      if (syllabus.regulation.isNotEmpty) syllabus.regulation,
    ];
    final String outcomes = syllabus.outcomes.take(6).join(' ');
    return '${parts.join(', ')}'
        '${outcomes.isEmpty ? '' : '\nCourse outcomes: ${outcomes.length > 600 ? '${outcomes.substring(0, 600)}…' : outcomes}'}';
  }

  SyllabusContext contextFor(String question, {String markScheme = ''}) {
    if (_units.isEmpty) return SyllabusContext.none;
    final Set<String> words = syllabusKeywords('$question $markScheme');

    // A unit the question names outright.
    final RegExpMatch? named = RegExp(r'\bunit\s*[-:.]?\s*([ivx]+|\d{1,2})\b', caseSensitive: false)
        .firstMatch(question);
    if (named != null) {
      final int? wanted = _number(named.group(1)!);
      for (final _IndexedUnit unit in _units) {
        if (wanted != null && _number(unit.unit.number) == wanted) return _describe(unit, words);
      }
    }

    _IndexedUnit? best;
    int bestShared = 0;
    int bestTitle = 0;
    for (final _IndexedUnit unit in _units) {
      final int shared = unit.vocabulary.intersection(words).length;
      final int title = unit.title.intersection(words).length;
      if (shared > bestShared || (shared == bestShared && title > bestTitle)) {
        best = unit;
        bestShared = shared;
        bestTitle = title;
      }
    }
    // Two shared words, or one in a short question — "What is MQTT?".
    final bool confident = bestShared >= 2 || (bestShared == 1 && words.length <= 3);
    if (best == null || !confident) return SyllabusContext.none;
    return _describe(best, words);
  }

  SyllabusContext _describe(_IndexedUnit unit, Set<String> words) {
    // Topics the question touches first, then the rest in syllabus order.
    final List<int> order = List<int>.generate(unit.topics.length, (int i) => i)
      ..sort((int a, int b) {
        final int byOverlap = unit.topics[b].intersection(words).length
            .compareTo(unit.topics[a].intersection(words).length);
        return byOverlap != 0 ? byOverlap : a.compareTo(b);
      });
    final String label = unit.unit.label;
    final StringBuffer text = StringBuffer(
      '$label${unit.unit.hours == null ? '' : ' (${unit.unit.hours} hours)'}:',
    );
    int used = 0;
    for (final int index in order) {
      final String topic = unit.unit.topics[index];
      if (text.length + topic.length + 2 > maxCharacters) break;
      text.write(used == 0 ? ' $topic' : '; $topic');
      used++;
    }
    if (used < unit.unit.topics.length) text.write('; …');
    final String focus = <String>[
      for (final int index in order)
        if (unit.topics[index].intersection(words).isNotEmpty) unit.unit.topics[index],
    ].join('; ');
    return SyllabusContext(label: label, text: text.toString(), focus: focus);
  }

  static int? _number(String value) {
    final int? arabic = int.tryParse(value.replaceAll(RegExp(r'^module\s*', caseSensitive: false), ''));
    if (arabic != null) return arabic;
    const Map<String, int> roman = <String, int>{'i': 1, 'v': 5, 'x': 10, 'l': 50};
    final String lower = value.toLowerCase();
    if (!RegExp(r'^[ivxl]+$').hasMatch(lower)) return null;
    int total = 0;
    for (int i = 0; i < lower.length; i++) {
      final int current = roman[lower[i]]!;
      final int next = i + 1 < lower.length ? roman[lower[i + 1]]! : 0;
      total += current < next ? -current : current;
    }
    return total;
  }
}

class _IndexedUnit {
  _IndexedUnit(this.unit, this.title, this.topics)
      : vocabulary = <String>{...title, for (final Set<String> t in topics) ...t};

  final SyllabusUnit unit;
  final Set<String> title;
  final List<Set<String>> topics;
  final Set<String> vocabulary;
}
