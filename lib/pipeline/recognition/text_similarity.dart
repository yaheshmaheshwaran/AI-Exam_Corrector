import 'dart:math' as math;

/// How alike two readings of the same writing are, 0..1.
///
/// Compared on content rather than presentation — case, spacing and
/// punctuation style differ between recognisers without the reading differing
/// — so a difference of one space is not a disagreement, but "2000" against
/// "200" is.
double textSimilarity(String a, String b) {
  final String left = normaliseForComparison(a);
  final String right = normaliseForComparison(b);
  if (left.isEmpty && right.isEmpty) return 1;
  if (left.isEmpty || right.isEmpty) return 0;

  // Bounded so a pathological region cannot stall the pipeline; the prefix
  // is plenty to tell agreement from disagreement.
  final String x = left.length > 1500 ? left.substring(0, 1500) : left;
  final String y = right.length > 1500 ? right.substring(0, 1500) : right;
  final int distance = _levenshtein(x, y);
  return 1 - distance / math.max(x.length, y.length);
}

String normaliseForComparison(String text) => text
    .toLowerCase()
    .replaceAll(RegExp(r'[^\w\s=+\-/*^.]'), '')
    .replaceAll(RegExp(r'\s+'), ' ')
    .replaceAll(RegExp(r'\s*([=+\-/*^])\s*'), r'$1')
    .trim();

int _levenshtein(String a, String b) {
  List<int> previous = List<int>.generate(b.length + 1, (int i) => i);
  List<int> current = List<int>.filled(b.length + 1, 0);
  for (int i = 1; i <= a.length; i++) {
    current[0] = i;
    for (int j = 1; j <= b.length; j++) {
      final int cost = a.codeUnitAt(i - 1) == b.codeUnitAt(j - 1) ? 0 : 1;
      current[j] = math.min(
        math.min(current[j - 1] + 1, previous[j] + 1),
        previous[j - 1] + cost,
      );
    }
    final List<int> swap = previous;
    previous = current;
    current = swap;
  }
  return previous[b.length];
}

/// True for a line that reads as working rather than prose: an equals sign or
/// several operators, and mostly digits and symbols.
bool looksMathematical(String line) {
  final String compact = line.replaceAll(RegExp(r'\s'), '');
  if (compact.length < 3) return false;
  final int symbols = RegExp(r'[0-9=+\-×÷/*^√πΣ∫<>≤≥()%.]').allMatches(compact).length;
  final int operators = RegExp(r'[=+×÷/*^√<>≤≥]').allMatches(compact).length;
  final bool hasRelation = compact.contains('=') || operators >= 2;
  return hasRelation && symbols / compact.length >= 0.4;
}
