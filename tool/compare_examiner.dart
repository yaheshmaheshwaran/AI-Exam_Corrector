// Compares the marks a model gave (from tool/mark_one_script.dart) with an
// examiner's, question by question.
//
//   dart run tool/compare_examiner.dart --examiner <csv> <marks folder> [<marks folder> …]
//
//   --examiner <csv>   the examiner's marks, columns script,question,marks
//                      (default ~/Documents/marklume-private/scriptA-examiner-marks.csv)
//
// Each marks folder is the --out folder of a marking run; give several to
// compare models, or two runs of one model to see how consistent it is.
//
// The examiner's marks are a hidden reference: this tool only reads them
// after marking has finished, and nothing it reads is ever sent to a model.
//
// A question counts as agreeing when the model is within the band teachers
// themselves differ by: 1 mark on a question worth up to 2, otherwise 15% of
// the question's maximum.
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

Future<void> main(List<String> args) async {
  String examinerPath =
      '${Platform.environment['HOME']}/Documents/marklume-private/scriptA-examiner-marks.csv';
  final List<String> runs = <String>[];
  for (int i = 0; i < args.length; i++) {
    if (args[i] == '--examiner' && i + 1 < args.length) {
      examinerPath = args[++i];
    } else {
      runs.add(args[i]);
    }
  }
  if (runs.isEmpty) {
    stderr.writeln('Give at least one marks folder (the --out folder of mark_one_script).');
    exitCode = 64;
    return;
  }
  final Map<String, double> examiner = _examiner(File(examinerPath));
  if (examiner.isEmpty) {
    stderr.writeln('No examiner marks in $examinerPath.');
    exitCode = 66;
    return;
  }

  final List<_Run> loaded = <_Run>[for (final String folder in runs) _Run.load(folder)];
  final List<String> questions = examiner.keys.toList();
  final StringBuffer table = StringBuffer();
  table.write('${'Question'.padRight(9)}${'Max'.padLeft(5)}${'Examiner'.padLeft(10)}');
  for (final _Run run in loaded) {
    table.write(run.name.padLeft(26));
  }
  table.writeln();

  for (final String question in questions) {
    final double expected = examiner[question]!;
    double? maximum;
    final List<String> cells = <String>[];
    for (final _Run run in loaded) {
      final ({double awarded, double maximum, bool counted})? mark = run.marks[question];
      maximum ??= mark?.maximum;
      if (mark == null) {
        cells.add('—'.padLeft(26));
        continue;
      }
      final double gap = mark.awarded - expected;
      final bool agrees = gap.abs() <= _band(mark.maximum);
      run.record(gap, agrees: agrees);
      cells.add('${_n(mark.awarded)} (${gap >= 0 ? '+' : ''}${_n(gap)})${agrees ? '' : ' ✗'}'.padLeft(26));
    }
    table.write('${question.padRight(9)}${(maximum == null ? '?' : _n(maximum)).padLeft(5)}${_n(expected).padLeft(10)}');
    cells.forEach(table.write);
    table.writeln();
  }

  final double examinerTotal = examiner.values.fold<double>(0, (double s, double v) => s + v);
  table.write('\n${'Total'.padRight(14)}${_n(examinerTotal).padLeft(10)}');
  for (final _Run run in loaded) {
    final double total = run.total ?? 0;
    table.write('${_n(total)} (${total - examinerTotal >= 0 ? '+' : ''}${_n(total - examinerTotal)})'.padLeft(26));
  }
  stdout.writeln(table);

  stdout.writeln('${'Agreeing questions'.padRight(24)}${loaded.map((_Run r) => '${r.agreeing}/${r.compared}'.padLeft(26)).join()}');
  stdout.writeln('${'Mean difference (marks)'.padRight(24)}${loaded.map((_Run r) => r.meanAbsolute.toStringAsFixed(2).padLeft(26)).join()}');
  stdout.writeln('${'Average lean'.padRight(24)}${loaded.map((_Run r) => '${r.lean >= 0 ? '+' : ''}${r.lean.toStringAsFixed(2)}'.padLeft(26)).join()}');
  stdout.writeln('\nA question agrees when within 1 mark (questions worth up to 2) or 15% of its maximum.\n'
      'Average lean: positive means more generous than the examiner, negative stricter.');
}

/// How far a model may be from the examiner and still agree with them.
double _band(double maximum) => maximum <= 2 ? 1 : math.max(1, 0.15 * maximum);

/// The examiner's marks by question label, normalised.
Map<String, double> _examiner(File file) {
  if (!file.existsSync()) return const <String, double>{};
  final Map<String, double> marks = <String, double>{};
  for (final String line in file.readAsLinesSync().skip(1)) {
    final List<String> cells = line.split(',');
    if (cells.length < 3) continue;
    final double? mark = double.tryParse(cells[2].trim());
    if (mark != null) marks[_label(cells[1])] = mark;
  }
  return marks;
}

/// "21(b)", "21 b", "Q21b" and "21b" are the same question.
String _label(String raw) => raw.toLowerCase().replaceAll(RegExp(r'^q\.?\s*'), '').replaceAll(RegExp('[^a-z0-9]'), '');

String _n(double value) => value == value.roundToDouble() ? value.toInt().toString() : value.toStringAsFixed(1);

class _Run {
  _Run(this.name, this.marks, this.total);

  factory _Run.load(String folder) {
    final Map<String, Object?> json =
        jsonDecode(File('$folder/marks.json').readAsStringSync()) as Map<String, Object?>;
    final Map<String, ({double awarded, double maximum, bool counted})> marks =
        <String, ({double awarded, double maximum, bool counted})>{};
    for (final Object? item in json['questions'] as List<Object?>) {
      final Map<String, Object?> q = item as Map<String, Object?>;
      marks[_label(q['question'] as String)] = (
        awarded: (q['awarded'] as num).toDouble(),
        maximum: (q['maximum'] as num).toDouble(),
        counted: q['counted'] as bool? ?? true,
      );
    }
    final String name = folder.split(Platform.pathSeparator).where((String p) => p.isNotEmpty).last;
    return _Run(name.length > 24 ? name.substring(name.length - 24) : name, marks, (json['total'] as num?)?.toDouble());
  }

  final String name;
  final Map<String, ({double awarded, double maximum, bool counted})> marks;
  final double? total;
  final List<double> _gaps = <double>[];
  int agreeing = 0;

  void record(double gap, {required bool agrees}) {
    _gaps.add(gap);
    if (agrees) agreeing++;
  }

  int get compared => _gaps.length;
  double get meanAbsolute =>
      _gaps.isEmpty ? 0 : _gaps.fold<double>(0, (double s, double g) => s + g.abs()) / _gaps.length;
  double get lean => _gaps.isEmpty ? 0 : _gaps.fold<double>(0, (double s, double g) => s + g) / _gaps.length;
}
