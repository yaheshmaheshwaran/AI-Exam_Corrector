import 'package:flutter/material.dart';

import 'package:exam_corrector/widgets/ui/skeleton.dart';

import 'package:exam_corrector/widgets/ui/select_field.dart';

import 'package:exam_corrector/app/app_colors.dart';
import 'package:exam_corrector/app/app_text.dart';
import 'package:exam_corrector/app/app_theme.dart';
import 'package:exam_corrector/core/utils/marks_format.dart';
import 'package:exam_corrector/domain/marking_standard.dart';
import 'package:exam_corrector/models/published_result.dart';
import 'package:exam_corrector/models/student_status.dart';
import 'package:exam_corrector/screens/requests/requests_screen.dart';
import 'package:exam_corrector/state/correction_controller.dart';
import 'package:exam_corrector/widgets/answer_view.dart';

/// Where every student stands: who has seen their result, who has verified
/// it, who is waiting on a correction — one table, filtered by subject and
/// exam, for chasing students and knowing when marks are final.
class StudentStatusScreen extends StatefulWidget {
  const StudentStatusScreen({super.key, required this.controller});

  final CorrectionController controller;

  static Future<void> open(BuildContext context, CorrectionController controller) =>
      Navigator.of(context).push(
        MaterialPageRoute<void>(builder: (BuildContext context) => StudentStatusScreen(controller: controller)),
      );

  @override
  State<StudentStatusScreen> createState() => _StudentStatusScreenState();
}

class _StudentStatusScreenState extends State<StudentStatusScreen> {
  List<StudentStatus>? _rows;
  List<String> _subjects = const <String>[];
  List<String> _exams = const <String>[];
  String? _subject;
  String? _exam;
  StudentStage? _stage;
  String _search = '';
  int _sortColumn = 0;
  bool _ascending = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final CorrectionController c = widget.controller;
    final List<String> subjects = await c.publishedSubjects();
    final List<String> exams = await c.examsFor(_subject);
    final String? exam = exams.contains(_exam) ? _exam : null;
    final List<StudentStatus> rows = await c.studentOverview(subjectCode: _subject, exam: exam);
    if (!mounted) return;
    setState(() {
      _subjects = subjects;
      _exams = exams;
      _exam = exam;
      _rows = rows;
    });
  }

  /// The rows the filters and the search leave, sorted.
  List<StudentStatus> get _shown {
    final String wanted = PublishedResult.normalise(_search);
    final List<StudentStatus> rows = <StudentStatus>[
      for (final StudentStatus r in _rows ?? const <StudentStatus>[])
        if ((_stage == null || r.stage == _stage) &&
            (wanted.isEmpty ||
                PublishedResult.normalise(r.rollNo).contains(wanted) ||
                PublishedResult.normalise(r.studentName).contains(wanted)))
          r,
    ];
    int by(StudentStatus a, StudentStatus b) => switch (_sortColumn) {
          1 => a.studentName.compareTo(b.studentName),
          2 => a.subjectCode.compareTo(b.subjectCode),
          3 => a.exam.compareTo(b.exam),
          4 => a.total.compareTo(b.total),
          5 => a.percentage.compareTo(b.percentage),
          6 => a.publishedAt.compareTo(b.publishedAt),
          7 => (a.firstSeenAt ?? DateTime(9999)).compareTo(b.firstSeenAt ?? DateTime(9999)),
          8 => (a.verifiedAt ?? DateTime(9999)).compareTo(b.verifiedAt ?? DateTime(9999)),
          9 => a.openRequests.compareTo(b.openRequests),
          10 => a.badges.compareTo(b.badges),
          _ => a.rollNo.compareTo(b.rollNo),
        };
    rows.sort((StudentStatus a, StudentStatus b) => _ascending ? by(a, b) : by(b, a));
    return rows;
  }

  void _sort(int column, bool ascending) => setState(() {
        _sortColumn = column;
        _ascending = ascending;
      });

  Future<void> _openResult(StudentStatus row) async {
    final PublishedResult? result = await widget.controller.publishedResult(row.resultId);
    if (result == null || !mounted) return;
    await Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (BuildContext context) => _ResultScreen(result: result),
    ));
  }

  Future<void> _openRequests(StudentStatus row) async {
    await RequestsScreen.open(context, widget.controller, rollNo: row.rollNo, subjectCode: row.subjectCode);
    await widget.controller.refreshRequests();
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final List<StudentStatus> all = _rows ?? const <StudentStatus>[];
    final List<StudentStatus> shown = _shown;
    int count(StudentStage stage) => all.where((StudentStatus r) => r.stage == stage).length;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Students'),
        actions: <Widget>[
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: OutlinedButton.icon(
              key: const Key('export-students'),
              onPressed: shown.isEmpty
                  ? null
                  : () => widget.controller.exportOverview(
                        shown,
                        name: 'students${_subject == null ? '' : ' $_subject'}${_exam == null ? '' : ' $_exam'}',
                      ),
              icon: const Icon(Icons.download_outlined, size: 16),
              label: const Text('Export CSV'),
            ),
          ),
        ],
      ),
      body: _rows == null
          ? const Padding(
              padding: EdgeInsets.all(AppTheme.pagePadding),
              child: Align(alignment: Alignment.topCenter, child: SkeletonTable(rows: 8, columns: 7, label: 'Loading students')),
            )
          : Padding(
              padding: const EdgeInsets.all(AppTheme.pagePadding),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  // How the class stands, each figure a filter.
                  Wrap(
                    spacing: 8,
                    runSpacing: 6,
                    children: <Widget>[
                      _Figure(
                        key: const Key('figure-all'),
                        label: 'Published',
                        value: all.length,
                        selected: _stage == null,
                        onTap: () => setState(() => _stage = null),
                      ),
                      for (final StudentStage stage in StudentStage.values)
                        _Figure(
                          key: ValueKey<String>('figure-${stage.name}'),
                          label: stage.label,
                          value: count(stage),
                          colour: _colour(stage),
                          selected: _stage == stage,
                          onTap: () => setState(() => _stage = _stage == stage ? null : stage),
                        ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Wrap(
                    spacing: 12,
                    runSpacing: 8,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: <Widget>[
                      SelectField<String?>(
                        key: const Key('filter-subject'),
                        value: _subject,
                        hint: const Text('All subjects'),
                        items: <DropdownMenuItem<String?>>[
                          const DropdownMenuItem<String?>(child: Text('All subjects')),
                          for (final String s in _subjects) DropdownMenuItem<String?>(value: s, child: Text(s)),
                        ],
                        onChanged: (String? s) {
                          setState(() => _subject = s);
                          _load();
                        },
                      ),
                      SelectField<String?>(
                        key: const Key('filter-exam'),
                        value: _exam,
                        hint: const Text('All exams'),
                        items: <DropdownMenuItem<String?>>[
                          const DropdownMenuItem<String?>(child: Text('All exams')),
                          for (final String e in _exams)
                            DropdownMenuItem<String?>(value: e, child: Text(e.isEmpty ? '(no exam name)' : e)),
                        ],
                        onChanged: (String? e) {
                          setState(() => _exam = e);
                          _load();
                        },
                      ),
                      SizedBox(
                        width: 240,
                        child: TextField(
                          key: const Key('filter-search'),
                          onChanged: (String v) => setState(() => _search = v),
                          decoration: const InputDecoration(
                            isDense: true,
                            prefixIcon: Icon(Icons.search, size: 18),
                            hintText: 'Roll number or name',
                          ),
                        ),
                      ),
                      Text('${shown.length} shown', style: theme.textTheme.bodySmall),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Expanded(
                    child: shown.isEmpty
                        ? Center(
                            child: Text(
                              all.isEmpty ? 'No results have been published yet.' : 'No students match.',
                              key: const Key('students-empty'),
                              style: context.text.muted,
                            ),
                          )
                        : SingleChildScrollView(
                            child: SingleChildScrollView(
                              scrollDirection: Axis.horizontal,
                              child: DataTable(
                                key: const Key('students-table'),
                                sortColumnIndex: _sortColumn,
                                sortAscending: _ascending,
                                showCheckboxColumn: false,
                                headingRowHeight: 40,
                                dataRowMinHeight: 40,
                                dataRowMaxHeight: 48,
                                columns: <DataColumn>[
                                  DataColumn(label: const Text('Roll no'), onSort: _sort),
                                  DataColumn(label: const Text('Name'), onSort: _sort),
                                  DataColumn(label: const Text('Subject'), onSort: _sort),
                                  DataColumn(label: const Text('Exam'), onSort: _sort),
                                  DataColumn(label: const Text('Marks'), numeric: true, onSort: _sort),
                                  DataColumn(label: const Text('%'), numeric: true, onSort: _sort),
                                  DataColumn(label: const Text('Published'), onSort: _sort),
                                  DataColumn(label: const Text('Seen'), onSort: _sort),
                                  DataColumn(label: const Text('Verified'), onSort: _sort),
                                  DataColumn(label: const Text('Requests'), onSort: _sort),
                                  DataColumn(
                                    label: const Tooltip(
                                      message: 'Answers that earned a syllabus badge',
                                      child: Text('Badges'),
                                    ),
                                    numeric: true,
                                    onSort: _sort,
                                  ),
                                ],
                                rows: <DataRow>[
                                  for (final StudentStatus row in shown)
                                    DataRow(
                                      key: ValueKey<String>('student-row-${row.resultId}'),
                                      color: WidgetStatePropertyAll<Color?>(_tint(row.stage)),
                                      onSelectChanged: (_) => _openResult(row),
                                      cells: <DataCell>[
                                        DataCell(Text(row.rollNo, style: theme.textTheme.titleSmall)),
                                        DataCell(Text(row.studentName.isEmpty ? '—' : row.studentName)),
                                        DataCell(Text(row.subjectCode)),
                                        DataCell(Text(row.exam.isEmpty ? '—' : row.exam)),
                                        DataCell(Text('${formatMarks(row.total)} / ${formatMarks(row.maximum)}')),
                                        DataCell(Text(formatPercentage(row.percentage))),
                                        DataCell(Text(_day(row.publishedAt))),
                                        DataCell(
                                          row.firstSeenAt == null
                                              ? Text('No', style: TextStyle(color: _colour(StudentStage.notSeen)))
                                              : Tooltip(
                                                  message: 'Opened ${row.seenCount} time${row.seenCount == 1 ? '' : 's'}, '
                                                      'last on ${_day(row.lastSeenAt!)}',
                                                  child: Text(_day(row.firstSeenAt!)),
                                                ),
                                        ),
                                        DataCell(
                                          row.verifiedAt == null
                                              ? const Text('—')
                                              : Row(
                                                  mainAxisSize: MainAxisSize.min,
                                                  children: <Widget>[
                                                    Icon(Icons.verified_outlined, size: 16, color: context.colors.success),
                                                    const SizedBox(width: 4),
                                                    Text(_day(row.verifiedAt!)),
                                                  ],
                                                ),
                                        ),
                                        DataCell(
                                          _Requests(row: row, onOpen: () => _openRequests(row)),
                                        ),
                                        DataCell(Text(row.badges == 0 ? '—' : '${row.badges}')),
                                      ],
                                    ),
                                ],
                              ),
                            ),
                          ),
                  ),
                ],
              ),
            ),
    );
  }

  static String _day(DateTime date) => date.toString().substring(0, 10);

  Color _colour(StudentStage stage) => switch (stage) {
        StudentStage.notSeen => context.colors.danger,
        StudentStage.seen => context.colors.textMuted,
        StudentStage.requested => context.colors.warning,
        StudentStage.verified => context.colors.success,
      };

  Color? _tint(StudentStage stage) => switch (stage) {
        StudentStage.notSeen => context.colors.dangerFill,
        StudentStage.seen => null,
        StudentStage.requested => context.colors.warningFill,
        StudentStage.verified => context.colors.successFill,
      };
}

/// A count at the top, which filters the table to it.
class _Figure extends StatelessWidget {
  const _Figure({
    super.key,
    required this.label,
    required this.value,
    required this.selected,
    required this.onTap,
    this.colour,
  });

  final String label;
  final int value;
  final bool selected;
  final VoidCallback onTap;
  final Color? colour;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return ChoiceChip(
      selected: selected,
      onSelected: (_) => onTap(),
      label: Text.rich(
        TextSpan(children: <InlineSpan>[
          TextSpan(text: '$value ', style: theme.textTheme.titleSmall?.copyWith(color: colour)),
          TextSpan(text: label, style: theme.textTheme.bodySmall),
        ]),
      ),
    );
  }
}

class _Requests extends StatelessWidget {
  const _Requests({required this.row, required this.onOpen});

  final StudentStatus row;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    if (row.openRequests == 0 && row.answeredRequests == 0) return const Text('—');
    final String text = <String>[
      if (row.openRequests > 0) '${row.openRequests} open',
      if (row.answeredRequests > 0) '${row.answeredRequests} answered',
    ].join(' · ');
    return TextButton(
      key: ValueKey<String>('row-requests-${row.resultId}'),
      onPressed: onOpen,
      child: Text(
        text,
        style: theme.textTheme.bodySmall?.copyWith(
          color: row.openRequests > 0 ? context.colors.warning : context.colors.textMuted,
          fontWeight: row.openRequests > 0 ? FontWeight.w600 : null,
        ),
      ),
    );
  }
}

/// One student's published result, as the teacher reviews it: the marks,
/// each answer, and the whole answer sheet.
class _ResultScreen extends StatelessWidget {
  const _ResultScreen({required this.result});

  final PublishedResult result;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          title: Text('${result.rollNo} · ${result.subjectCode}${result.exam.isEmpty ? '' : ' · ${result.exam}'}'),
          bottom: TabBar(
            tabs: <Widget>[
              const Tab(text: 'Marks and answers'),
              Tab(text: 'Answer sheet${result.pages.isEmpty ? '' : ' (${result.pages.length} pages)'}'),
            ],
          ),
        ),
        body: TabBarView(
          children: <Widget>[
            ListView(
              padding: const EdgeInsets.all(AppTheme.pagePadding),
              children: <Widget>[
                Text(
                  'Total ${formatMarks(result.total)} / ${formatMarks(result.maximum)} · '
                  '${formatPercentage(result.percentage)}'
                  '${result.isVerified ? ' · verified by the student' : ''}',
                  key: const Key('teacher-result-total'),
                  style: theme.textTheme.titleMedium,
                ),
                const SizedBox(height: 10),
                for (final PublishedQuestion q in result.questions)
                  Card(
                    margin: const EdgeInsets.only(bottom: 8),
                    child: ExpansionTile(
                      title: Text('Question ${q.number}'),
                      trailing: Text(
                        '${formatMarks(q.marks)} / ${formatMarks(q.maximum)}'
                        '${q.badge == SyllabusBadge.none ? '' : '  ★ ${q.badge.label}${q.bonus > 0 ? ' +${formatMarks(q.bonus)}' : ''}'}',
                        style: q.badge == SyllabusBadge.none
                            ? null
                            : TextStyle(color: context.colors.bonus, fontWeight: FontWeight.w600),
                      ),
                      childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                      children: <Widget>[QuestionAnswerView(question: q, pages: result.pages, pageHeight: 360)],
                    ),
                  ),
              ],
            ),
            AnswerSheetView(pages: result.pages),
          ],
        ),
      ),
    );
  }
}
