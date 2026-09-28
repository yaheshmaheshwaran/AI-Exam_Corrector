import 'package:flutter/material.dart';

import 'package:exam_corrector/widgets/ui/skeleton.dart';

import 'package:exam_corrector/app/app_colors.dart';
import 'package:exam_corrector/app/app_text.dart';
import 'package:exam_corrector/app/app_theme.dart';
import 'package:exam_corrector/core/utils/marks_format.dart';
import 'package:exam_corrector/models/correction_request.dart';
import 'package:exam_corrector/models/published_result.dart';
import 'package:exam_corrector/state/correction_controller.dart';
import 'package:exam_corrector/widgets/answer_view.dart';

/// Students' requests to look again at a mark: the list on the left, and on
/// the right the chosen request beside the answer itself — the student's
/// reason, what was read, their pages with the answer outlined — and the
/// decision, made right there.
class RequestsScreen extends StatefulWidget {
  const RequestsScreen({super.key, required this.controller, this.rollNo, this.subjectCode});

  final CorrectionController controller;

  /// Only this student's requests, in this subject, when given.
  final String? rollNo;
  final String? subjectCode;

  static Future<void> open(
    BuildContext context,
    CorrectionController controller, {
    String? rollNo,
    String? subjectCode,
  }) =>
      Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (BuildContext context) =>
              RequestsScreen(controller: controller, rollNo: rollNo, subjectCode: subjectCode),
        ),
      );

  @override
  State<RequestsScreen> createState() => _RequestsScreenState();
}

class _RequestsScreenState extends State<RequestsScreen> {
  bool _openOnly = true;
  String? _subject;
  List<CorrectionRequest>? _requests;
  int? _selected;

  @override
  void initState() {
    super.initState();
    _load();
  }

  /// Reloads the list; keeps the selection, or moves to the next waiting
  /// request when the chosen one was just answered.
  Future<void> _load({bool advance = false}) async {
    final List<CorrectionRequest> found = await widget.controller.correctionRequests(
      openOnly: _openOnly,
      rollNo: widget.rollNo,
      subjectCode: widget.subjectCode,
    );
    if (!mounted) return;
    setState(() {
      _requests = found;
      final bool stillThere = found.any((CorrectionRequest r) => r.id == _selected);
      if (advance || !stillThere) {
        _selected = found.where((CorrectionRequest r) => r.isOpen).firstOrNull?.id ?? found.firstOrNull?.id;
      }
    });
  }

  List<CorrectionRequest> get _shown => (_requests ?? const <CorrectionRequest>[])
      .where((CorrectionRequest r) => _subject == null || r.subjectCode == _subject)
      .toList();

  @override
  Widget build(BuildContext context) {
    final List<CorrectionRequest> all = _requests ?? const <CorrectionRequest>[];
    final List<String> subjects = <String>{for (final CorrectionRequest r in all) r.subjectCode}.toList()..sort();
    final CorrectionRequest? selected = _shown.where((CorrectionRequest r) => r.id == _selected).firstOrNull;

    return Scaffold(
      appBar: AppBar(
        title: Text(widget.rollNo == null ? 'Correction requests' : 'Correction requests · ${widget.rollNo}'),
        actions: <Widget>[
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: SegmentedButton<bool>(
              showSelectedIcon: false,
              segments: const <ButtonSegment<bool>>[
                ButtonSegment<bool>(value: true, label: Text('Waiting')),
                ButtonSegment<bool>(value: false, label: Text('All')),
              ],
              selected: <bool>{_openOnly},
              onSelectionChanged: (Set<bool> picked) {
                setState(() => _openOnly = picked.single);
                _load();
              },
            ),
          ),
        ],
      ),
      body: _requests == null
          ? const Padding(
              padding: EdgeInsets.all(12),
              child: Align(alignment: Alignment.topLeft, child: SizedBox(width: 360, child: SkeletonRows(count: 5, label: 'Loading requests'))),
            )
          : LayoutBuilder(
              builder: (BuildContext context, BoxConstraints constraints) {
                final Widget list = _List(
                  requests: _shown,
                  subjects: subjects,
                  subject: _subject,
                  selected: _selected,
                  openOnly: _openOnly,
                  onSubject: (String? code) => setState(() => _subject = code),
                  onSelect: (CorrectionRequest r) {
                    setState(() => _selected = r.id);
                    if (constraints.maxWidth < 900) {
                      Navigator.of(context).push(MaterialPageRoute<void>(
                        builder: (BuildContext context) => Scaffold(
                          appBar: AppBar(title: Text('Question ${r.questionNumber} · ${r.rollNo}')),
                          body: _Detail(
                            key: ValueKey<int>(r.id),
                            request: r,
                            controller: widget.controller,
                            onDone: () {
                              Navigator.of(context).pop();
                              _load(advance: true);
                            },
                          ),
                        ),
                      ));
                    }
                  },
                );
                if (constraints.maxWidth < 900) return list;
                return Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    SizedBox(width: 380, child: list),
                    const VerticalDivider(width: 1),
                    Expanded(
                      child: selected == null
                          ? const Center(child: Text('Choose a request to see the answer.'))
                          : _Detail(
                              key: ValueKey<int>(selected.id),
                              request: selected,
                              controller: widget.controller,
                              onDone: () => _load(advance: true),
                            ),
                    ),
                  ],
                );
              },
            ),
    );
  }
}

class _List extends StatelessWidget {
  const _List({
    required this.requests,
    required this.subjects,
    required this.subject,
    required this.selected,
    required this.openOnly,
    required this.onSubject,
    required this.onSelect,
  });

  final List<CorrectionRequest> requests;
  final List<String> subjects;
  final String? subject;
  final int? selected;
  final bool openOnly;
  final ValueChanged<String?> onSubject;
  final ValueChanged<CorrectionRequest> onSelect;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return ListView(
      padding: const EdgeInsets.all(12),
      children: <Widget>[
        if (subjects.length > 1)
          Wrap(
            spacing: 6,
            runSpacing: 4,
            children: <Widget>[
              ChoiceChip(label: const Text('All subjects'), selected: subject == null, onSelected: (_) => onSubject(null)),
              for (final String code in subjects)
                ChoiceChip(label: Text(code), selected: subject == code, onSelected: (_) => onSubject(code)),
            ],
          ),
        if (requests.isEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 40),
            child: Center(
              child: Text(
                openOnly ? 'No requests waiting.' : 'No requests yet.',
                key: const Key('requests-empty'),
                style: context.text.muted,
              ),
            ),
          ),
        for (final CorrectionRequest request in requests)
          Card(
            color: request.id == selected ? context.colors.primarySoft : null,
            margin: const EdgeInsets.only(top: 6),
            child: ListTile(
              key: ValueKey<String>('request-row-${request.id}'),
              onTap: () => onSelect(request),
              title: Text(
                '${request.rollNo} · Q${request.questionNumber}',
                style: theme.textTheme.titleSmall,
              ),
              subtitle: Text(
                '${request.subjectCode}${request.exam.isEmpty ? '' : ' · ${request.exam}'}\n“${request.message}”',
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              trailing: Text(
                request.isOpen
                    ? '${formatMarks(request.currentMarks)}/${formatMarks(request.maximum)}'
                    : request.status.label,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: request.isOpen ? context.colors.primary : context.colors.textMuted,
                ),
              ),
            ),
          ),
      ],
    );
  }
}

/// One request, beside the answer it is about, with the decision inline.
class _Detail extends StatefulWidget {
  const _Detail({super.key, required this.request, required this.controller, required this.onDone});

  final CorrectionRequest request;
  final CorrectionController controller;
  final VoidCallback onDone;

  @override
  State<_Detail> createState() => _DetailState();
}

class _DetailState extends State<_Detail> {
  late final TextEditingController _marks =
      TextEditingController(text: formatMarks(widget.request.currentMarks));
  final TextEditingController _reply = TextEditingController();
  PublishedResult? _result;
  bool _loading = true;
  bool _saving = false;

  CorrectionRequest get _request => widget.request;

  @override
  void initState() {
    super.initState();
    widget.controller.publishedResult(_request.resultId).then((PublishedResult? result) {
      if (mounted) {
        setState(() {
          _result = result;
          _loading = false;
        });
      }
    });
  }

  @override
  void dispose() {
    _marks.dispose();
    _reply.dispose();
    super.dispose();
  }

  double? get _value {
    final double? value = double.tryParse(_marks.text.trim());
    if (value == null || value < 0 || value > _request.maximum + 1e-9) return null;
    return value;
  }

  /// The paper's mark step, from the standard it was marked to.
  double get _step {
    final String standard = _result?.standard ?? '';
    if (standard.contains('whole marks')) return 1;
    if (standard.contains('quarter marks')) return 0.25;
    return 0.5;
  }

  void _nudge(double by) {
    final double next = ((_value ?? _request.currentMarks) + by).clamp(0, _request.maximum).toDouble();
    setState(() => _marks.text = formatMarks(next));
  }

  Future<void> _change() async {
    final double? value = _value;
    if (value == null) return;
    setState(() => _saving = true);
    final bool done = await widget.controller.acceptRequest(_request, value, _reply.text.trim());
    if (!mounted) return;
    setState(() => _saving = false);
    if (done) widget.onDone();
  }

  Future<void> _keep() async {
    setState(() => _saving = true);
    final bool done = await widget.controller.declineRequest(_request, _reply.text.trim());
    if (!mounted) return;
    setState(() => _saving = false);
    if (done) widget.onDone();
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final CorrectionRequest request = _request;
    final PublishedResult? result = _result;
    final PublishedQuestion? question =
        result?.questions.where((PublishedQuestion q) => q.questionId == request.questionId).firstOrNull;
    final double? value = _value;
    final bool changed = value != null && (value - request.currentMarks).abs() > 1e-9;

    return ListView(
      padding: const EdgeInsets.all(AppTheme.pagePadding),
      children: <Widget>[
        Text(
          '${request.rollNo}${request.studentName.isEmpty ? '' : ' · ${request.studentName}'}'
          '  ·  ${request.subjectCode}${request.exam.isEmpty ? '' : ' · ${request.exam}'}',
          style: context.text.caption,
        ),
        Row(
          children: <Widget>[
            Expanded(child: Text('Question ${request.questionNumber}', style: theme.textTheme.titleLarge)),
            Text(
              '${formatMarks(request.currentMarks)} / ${formatMarks(request.maximum)}',
              style: theme.textTheme.titleLarge?.copyWith(color: context.colors.primary),
            ),
          ],
        ),
        const SizedBox(height: 10),
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: context.colors.warningFill,
            borderRadius: BorderRadius.circular(AppTheme.controlRadius),
          ),
          child: Text('The student asks: “${request.message}”', key: const Key('detail-reason'),
              style: theme.textTheme.bodyMedium),
        ),
        if (request.explanation.isNotEmpty) ...<Widget>[
          const SizedBox(height: 8),
          Text('Marked because: ${request.explanation}',
              style: context.text.caption),
        ],
        const SizedBox(height: 14),

        // The decision, right here.
        if (request.isOpen)
          Card(
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      IconButton(
                        key: const Key('mark-down'),
                        tooltip: '−${formatMarks(_step)}',
                        onPressed: () => _nudge(-_step),
                        icon: const Icon(Icons.remove_circle_outline),
                      ),
                      SizedBox(
                        width: 120,
                        child: TextField(
                          key: const Key('detail-marks'),
                          controller: _marks,
                          textAlign: TextAlign.center,
                          keyboardType: const TextInputType.numberWithOptions(decimal: true),
                          onChanged: (_) => setState(() {}),
                          decoration: InputDecoration(
                            labelText: 'New mark',
                            helperText: 'of ${formatMarks(request.maximum)}',
                            errorText: value == null ? 'Out of range' : null,
                          ),
                        ),
                      ),
                      IconButton(
                        key: const Key('mark-up'),
                        tooltip: '+${formatMarks(_step)}',
                        onPressed: () => _nudge(_step),
                        icon: const Icon(Icons.add_circle_outline),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: TextField(
                          key: const Key('detail-reply'),
                          controller: _reply,
                          minLines: 2,
                          maxLines: 4,
                          onChanged: (_) => setState(() {}),
                          decoration: const InputDecoration(labelText: 'Reply to the student'),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: <Widget>[
                      OutlinedButton(
                        key: const Key('keep-mark'),
                        onPressed: _saving || _reply.text.trim().isEmpty ? null : _keep,
                        child: const Text('Keep mark'),
                      ),
                      const SizedBox(width: 8),
                      FilledButton.icon(
                        key: const Key('change-mark'),
                        onPressed: _saving || !changed ? null : _change,
                        icon: const Icon(Icons.check, size: 16),
                        label: Text(changed
                            ? 'Change mark to ${formatMarks(value)}'
                            : 'Change mark'),
                      ),
                    ],
                  ),
                  Text(
                    'Keeping the mark needs a reply saying why.',
                    style: context.text.caption,
                  ),
                ],
              ),
            ),
          )
        else
          Text(
            request.status == RequestStatus.accepted
                ? 'Accepted: ${formatMarks(request.oldMarks ?? 0)} → ${formatMarks(request.newMarks ?? 0)}. '
                    'You replied: ${request.reply}'
                : 'Kept at ${formatMarks(request.oldMarks ?? request.currentMarks)}. You replied: ${request.reply}',
            style: theme.textTheme.bodyMedium,
          ),
        const SizedBox(height: 16),

        // The answer itself.
        if (_loading)
          const SkeletonLines(lines: 4, label: "Loading the student's answer")
        else if (question == null)
          Text('This result is no longer published.', style: theme.textTheme.bodyMedium)
        else ...<Widget>[
          Row(
            children: <Widget>[
              Text("The student's answer", style: theme.textTheme.titleMedium),
              const Spacer(),
              if (result!.pages.isNotEmpty)
                TextButton.icon(
                  key: const Key('open-sheet'),
                  onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(
                    builder: (BuildContext context) => Scaffold(
                      appBar: AppBar(title: Text('${request.rollNo} · answer sheet')),
                      body: AnswerSheetView(pages: result.pages),
                    ),
                  )),
                  icon: const Icon(Icons.menu_book_outlined, size: 16),
                  label: const Text('Open whole answer sheet'),
                ),
            ],
          ),
          const SizedBox(height: 6),
          QuestionAnswerView(question: question, pages: result.pages, pageHeight: 520),
        ],
      ],
    );
  }
}
