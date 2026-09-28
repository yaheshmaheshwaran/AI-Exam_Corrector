import 'package:flutter/material.dart';

import 'package:exam_corrector/core/errors/app_exception.dart';
import 'package:exam_corrector/core/utils/marks_format.dart';
import 'package:exam_corrector/domain/marking_standard.dart';
import 'package:exam_corrector/models/account.dart';
import 'package:exam_corrector/models/correction_request.dart';
import 'package:exam_corrector/models/published_result.dart';
import 'package:exam_corrector/services/results/results_repository.dart';
import 'package:exam_corrector/widgets/answer_view.dart';
import 'package:exam_corrector/widgets/syllabus_badge.dart';
import 'package:exam_corrector/widgets/text_prompt_dialog.dart';
import 'package:exam_corrector/widgets/ui/ui.dart';

/// What a student sees: the results published to their roll number, every
/// subject or one — and a way to ask the teacher to look again at a mark.
/// Nothing else can be changed from here.
class StudentScreen extends StatefulWidget {
  const StudentScreen({
    super.key,
    required this.results,
    required this.rollNo,
    required this.onSwitchRole,
    this.account,
  });

  final ResultsRepository? results;

  /// The signed-in student's roll number: the only results they see.
  final String rollNo;
  final VoidCallback onSwitchRole;
  final Account? account;

  @override
  State<StudentScreen> createState() => _StudentScreenState();
}

class _StudentScreenState extends State<StudentScreen> {
  final TextEditingController _subject = TextEditingController();
  List<PublishedResult>? _found;
  List<CorrectionRequest> _requests = const <CorrectionRequest>[];
  PublishedResult? _open;
  String _asked = '';
  bool _searching = false;

  String? _error;

  @override
  void initState() {
    super.initState();
    _search();
  }

  @override
  void dispose() {
    _subject.dispose();
    super.dispose();
  }

  Future<void> _search() async {
    final ResultsRepository? results = widget.results;
    final String roll = widget.rollNo.trim();
    if (results == null || roll.isEmpty) return;
    setState(() {
      _searching = true;
      _error = null;
    });
    try {
      final List<PublishedResult> found = await results.resultsFor(rollNo: roll, subjectCode: _subject.text);
      final List<CorrectionRequest> requests = await results.requests(rollNo: roll, subjectCode: _subject.text);
      if (!mounted) return;
      setState(() {
        _found = found;
        _requests = requests;
        _asked = '${PublishedResult.normaliseRoll(roll)}'
            '${_subject.text.trim().isEmpty ? '' : ' in ${PublishedResult.normaliseRoll(_subject.text)}'}';
        _open = null;
      });
    } on AppException catch (error) {
      if (mounted) setState(() => _error = error.message);
    } finally {
      if (mounted) setState(() => _searching = false);
    }
  }

  /// Reloads the open result and its requests after a change.
  Future<void> _refresh() async {
    final ResultsRepository? results = widget.results;
    final PublishedResult? open = _open;
    if (results == null) return;
    final PublishedResult? fresh = open == null ? null : await results.result(open.id);
    final List<CorrectionRequest> requests = await results.requests(rollNo: widget.rollNo, subjectCode: _subject.text);
    if (!mounted) return;
    setState(() {
      _open = fresh;
      _requests = requests;
      if (fresh != null) {
        _found = <PublishedResult>[
          for (final PublishedResult r in _found ?? const <PublishedResult>[]) r.id == fresh.id ? fresh : r,
        ];
      }
    });
  }

  Future<void> _requestCorrection(PublishedResult result, PublishedQuestion question) async {
    final ResultsRepository? results = widget.results;
    if (results == null) return;
    final String? message = await TextPromptDialog.show(
      context,
      title: 'Ask about question ${question.number}',
      intro: 'You have ${formatMarks(question.marks)} of ${formatMarks(question.maximum)}. '
          'Your teacher will look again and reply.',
      label: 'Why should it be looked at again? *',
      hint: 'e.g. I wrote the unit on page 3.',
      confirm: 'Send to teacher',
      fieldKey: const Key('request-reason'),
      confirmKey: const Key('request-send'),
      preview: AnswerPagePreview(question: question, pages: result.pages),
    );
    if (message == null) return;
    try {
      await results.requestCorrection(resultId: result.id, questionId: question.questionId, message: message);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Sent. Your teacher will reply about question ${question.number}.')),
      );
    } on AppException catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(error.message)));
    }
    await _refresh();
  }

  /// Opens a result, recording that the student has seen it.
  Future<void> _openResult(PublishedResult result) async {
    final ResultsRepository? results = widget.results;
    if (results == null) return;
    await results.markSeen(result.id);
    final PublishedResult? fresh = await results.result(result.id);
    if (!mounted) return;
    setState(() {
      _open = fresh ?? result;
      _found = <PublishedResult>[
        for (final PublishedResult r in _found ?? const <PublishedResult>[]) r.id == result.id ? (fresh ?? r) : r,
      ];
    });
  }

  /// A result's state, as the list shows it.
  String _stateOf(PublishedResult result) {
    if (result.isVerified) return 'Verified';
    if (_requests.any((CorrectionRequest r) => r.resultId == result.id && r.isOpen)) return 'Request waiting';
    return result.isSeen ? 'Seen' : 'New';
  }

  Future<void> _verify(PublishedResult result) async {
    final ResultsRepository? results = widget.results;
    if (results == null) return;
    final bool? sure = await showAppDialog<bool>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: const Text('Verify my marks'),
        content: SizedBox(
          width: 440,
          child: Text(
            'I have looked at my marks and my answers for ${result.subjectCode}'
            '${result.exam.isEmpty ? '' : ' · ${result.exam}'} and agree with them.\n\n'
            'After verifying you can no longer ask for corrections to this result.',
          ),
        ),
        actions: <Widget>[
          TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Not yet')),
          FilledButton(
            key: const Key('verify-confirm'),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('I agree — verify'),
          ),
        ],
      ),
    );
    if (!(sure ?? false)) return;
    try {
      await results.verify(result.id);
    } on AppException catch (error) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(error.message)));
    }
    await _refresh();
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final PublishedResult? open = _open;

    return Scaffold(
      body: Column(
        children: <Widget>[
          Container(
            height: 48,
            padding: const EdgeInsets.symmetric(horizontal: AppTheme.pagePadding),
            decoration: BoxDecoration(
              color: context.colors.surface,
              border: Border(bottom: BorderSide(color: context.colors.border)),
            ),
            child: Row(
              children: <Widget>[
                Icon(Icons.school_outlined, size: 18, color: context.colors.primary),
                const SizedBox(width: 10),
                Text('Marklume · Student', style: theme.textTheme.titleMedium),
                const SizedBox(width: 14),
                Expanded(
                  child: Text(
                    _whoAmI(),
                    key: const Key('student-who'),
                    overflow: TextOverflow.ellipsis,
                    style: context.text.caption,
                  ),
                ),
                OutlinedButton.icon(
                  key: const Key('switch-role'),
                  onPressed: widget.onSwitchRole,
                  icon: const Icon(Icons.logout, size: 16),
                  label: const Text('Sign out'),
                ),
              ],
            ),
          ),
          Expanded(
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 860),
                child: open == null
                    ? _finder(theme)
                    : _ResultView(
                        result: open,
                        requests: _requests.where((CorrectionRequest r) => r.resultId == open.id).toList(),
                        onBack: () => setState(() => _open = null),
                        onRequest: (PublishedQuestion q) => _requestCorrection(open, q),
                        onVerify: () => _verify(open),
                      ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Name, roll number and college, as the header shows them.
  String _whoAmI() {
    final Account? account = widget.account;
    if (account == null) return PublishedResult.normaliseRoll(widget.rollNo);
    return '${account.fullName} · ${account.memberId} · ${account.college.name}';
  }

  Widget _finder(ThemeData theme) {
    final List<PublishedResult>? found = _found;
    return ListView(
      padding: const EdgeInsets.all(AppTheme.pagePadding),
      children: <Widget>[
        Text('Your marks', style: theme.textTheme.titleLarge),
        const SizedBox(height: 4),
        Text(
          'Every result published to your roll number. Type a subject code to see one subject.',
          style: context.text.muted,
        ),
        const SizedBox(height: 12),
        Row(
          children: <Widget>[
            Expanded(
              child: TextField(
                key: const Key('student-subject'),
                controller: _subject,
                onSubmitted: (_) => _search(),
                decoration: const InputDecoration(
                  labelText: 'Subject code (optional)',
                  hintText: 'e.g. CCS356',
                  prefixIcon: Icon(Icons.filter_list, size: 18),
                ),
              ),
            ),
            const SizedBox(width: 10),
            FilledButton(
              key: const Key('student-search'),
              onPressed: _searching ? null : _search,
              child: const Text('Show'),
            ),
          ],
        ),
        const SizedBox(height: 20),
        if (_error != null) InfoBanner(key: const Key('student-error'), title: _error!, tone: ToneKind.danger),
        if (_searching) const SkeletonRows(count: 3, label: 'Finding your results'),
        if (!_searching && found != null && found.isEmpty)
          Text(
            'No results have been published for $_asked yet. Check the subject code, or ask your teacher.',
            key: const Key('student-none'),
            style: context.text.muted,
          ),
        if (!_searching && found != null)
          for (final PublishedResult result in found)
            Card(
              margin: const EdgeInsets.only(bottom: 8),
              child: ListTile(
                key: ValueKey<String>('student-result-${result.id}'),
                onTap: () => _openResult(result),
                title: Text(
                  '${result.subjectCode}${result.exam.isEmpty ? '' : ' · ${result.exam}'}',
                  style: theme.textTheme.titleSmall,
                ),
                subtitle: Text('${result.paperTitle} · published ${result.publishedAt.toString().substring(0, 10)}'
                    ' · ${_stateOf(result)}'),
                trailing: Text(
                  '${formatMarks(result.total)} / ${formatMarks(result.maximum)}  ·  ${formatPercentage(result.percentage)}',
                  style: theme.textTheme.titleSmall?.copyWith(color: context.colors.primary),
                ),
              ),
            ),
      ],
    );
  }
}

/// One published result: the total and sections, then two tabs — the marks
/// question by question, each with its answer, and the whole answer sheet.
class _ResultView extends StatelessWidget {
  const _ResultView({
    required this.result,
    required this.requests,
    required this.onBack,
    required this.onRequest,
    required this.onVerify,
  });

  final PublishedResult result;
  final List<CorrectionRequest> requests;
  final VoidCallback onBack;
  final ValueChanged<PublishedQuestion> onRequest;
  final VoidCallback onVerify;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final TextStyle muted = context.text.caption;

    return DefaultTabController(
      length: 2,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(AppTheme.pagePadding, AppTheme.pagePadding, AppTheme.pagePadding, 0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                key: const Key('student-back'),
                onPressed: onBack,
                icon: const Icon(Icons.arrow_back, size: 16),
                label: const Text('All my results'),
              ),
            ),
            Text('${result.subjectCode}${result.exam.isEmpty ? '' : ' · ${result.exam}'}', style: theme.textTheme.titleLarge),
            Text('${result.rollNo}${result.student.isEmpty ? '' : ' · ${result.student}'} · ${result.paperTitle}', style: muted),
            const SizedBox(height: 10),
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: context.colors.primarySoft,
                border: Border.all(color: context.colors.primaryBorder),
                borderRadius: BorderRadius.circular(AppTheme.controlRadius),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    'Total: ${formatMarks(result.total)} / ${formatMarks(result.maximum)}   ·   '
                    '${formatPercentage(result.percentage)}',
                    key: const Key('student-total'),
                    style: theme.textTheme.titleLarge?.copyWith(fontSize: 18),
                  ),
                  if (result.sections.isNotEmpty)
                    Text(
                      result.sections
                          .map((PublishedSection s) => '${s.title}: ${formatMarks(s.marks)}/${formatMarks(s.maximum)}')
                          .join('   ·   '),
                      style: theme.textTheme.bodySmall,
                    ),
                  if (result.standard.isNotEmpty) Text('Marked to: ${result.standard}', style: muted),
                ],
              ),
            ),
            const SizedBox(height: 8),
            _VerifyBar(
              result: result,
              requestOpen: requests.any((CorrectionRequest r) => r.isOpen),
              onVerify: onVerify,
            ),
            const SizedBox(height: 6),
            TabBar(
              isScrollable: true,
              tabAlignment: TabAlignment.start,
              tabs: <Widget>[
                const Tab(key: Key('tab-marks'), text: 'Marks by question'),
                Tab(
                  key: const Key('tab-sheet'),
                  text: 'My answer sheet${result.pages.isEmpty ? '' : ' (${result.pages.length} pages)'}',
                ),
              ],
            ),
            Expanded(
              child: TabBarView(
                children: <Widget>[
                  // Each card can open the student's answer, page crops and
                  // all: built only as it scrolls into view.
                  ListView.builder(
                    padding: const EdgeInsets.only(top: 10, bottom: AppTheme.pagePadding),
                    itemCount: result.questions.length,
                    itemBuilder: (BuildContext context, int index) {
                      final PublishedQuestion question = result.questions[index];
                      return _QuestionCard(
                        question: question,
                        pages: result.pages,
                        latest: requests.where((CorrectionRequest r) => r.questionId == question.questionId).firstOrNull,
                        onRequest: () => onRequest(question),
                        verified: result.isVerified,
                      );
                    },
                  ),
                  AnswerSheetView(pages: result.pages),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _QuestionCard extends StatefulWidget {
  const _QuestionCard({
    required this.question,
    required this.pages,
    required this.latest,
    required this.onRequest,
    this.verified = false,
  });

  /// The student verified the result: no more requests.
  final bool verified;

  final PublishedQuestion question;
  final List<PublishedPage> pages;

  /// The most recent request about this question, if any.
  final CorrectionRequest? latest;
  final VoidCallback onRequest;

  @override
  State<_QuestionCard> createState() => _QuestionCardState();
}

class _QuestionCardState extends State<_QuestionCard> {
  bool _showAnswer = false;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final PublishedQuestion question = widget.question;
    final CorrectionRequest? request = widget.latest;
    return Opacity(
      opacity: question.counted ? 1 : 0.55,
      child: Card(
        margin: const EdgeInsets.only(bottom: 8),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Row(
                children: <Widget>[
                  Expanded(
                    child: Text(
                      'Question ${question.number}${question.counted ? '' : '  (not counted — the other alternative counts)'}',
                      style: theme.textTheme.titleSmall,
                    ),
                  ),
                  if (question.badge != SyllabusBadge.none) ...<Widget>[
                    SyllabusBadgeChip(
                      badge: question.badge,
                      bonus: question.bonus,
                      tooltip: question.bonus > 0
                          ? 'Your answer covers what the syllabus teaches here: '
                              '+${formatMarks(question.bonus)} bonus, included in your marks.'
                          : 'Your answer covers what the syllabus teaches here.',
                    ),
                    const SizedBox(width: 8),
                  ],
                  Text(
                    '${formatMarks(question.marks)} / ${formatMarks(question.maximum)}',
                    key: ValueKey<String>('student-marks-${question.questionId}'),
                    style: theme.textTheme.titleSmall?.copyWith(
                      color: question.badge == SyllabusBadge.none ? context.colors.primary : context.colors.bonus,
                    ),
                  ),
                ],
              ),
              if (question.explanation.isNotEmpty) ...<Widget>[
                const SizedBox(height: 4),
                Text(question.explanation, style: theme.textTheme.bodySmall),
              ],
              if (question.comment.isNotEmpty) ...<Widget>[
                const SizedBox(height: 4),
                Text('Teacher: ${question.comment}',
                    style: theme.textTheme.bodySmall?.copyWith(color: context.colors.primary)),
              ],
              const SizedBox(height: 6),
              if (request != null) _Status(request: request),
              Wrap(
                spacing: 4,
                children: <Widget>[
                  TextButton.icon(
                    key: ValueKey<String>('view-answer-${question.questionId}'),
                    onPressed: () => setState(() => _showAnswer = !_showAnswer),
                    icon: Icon(_showAnswer ? Icons.expand_less : Icons.visibility_outlined, size: 16),
                    label: Text(_showAnswer ? 'Hide my answer' : 'View my answer'),
                  ),
                  if (!widget.verified && (request == null || !request.isOpen))
                    TextButton.icon(
                      key: ValueKey<String>('request-${question.questionId}'),
                      onPressed: question.counted ? widget.onRequest : null,
                      icon: const Icon(Icons.rate_review_outlined, size: 16),
                      label: const Text('Request correction'),
                    ),
                ],
              ),
              if (_showAnswer) ...<Widget>[
                const Divider(),
                QuestionAnswerView(question: question, pages: widget.pages),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// Verification: the badge once done, else the button — held back while a
/// request waits for the teacher.
class _VerifyBar extends StatelessWidget {
  const _VerifyBar({required this.result, required this.requestOpen, required this.onVerify});

  final PublishedResult result;
  final bool requestOpen;
  final VoidCallback onVerify;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final DateTime? verified = result.verifiedAt;
    if (verified != null) {
      return Container(
        key: const Key('verified-badge'),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(color: context.colors.successFill, borderRadius: BorderRadius.circular(4)),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(Icons.verified_outlined, size: 16, color: context.colors.success),
            const SizedBox(width: 6),
            Text(
              'You verified these marks on ${verified.toString().substring(0, 10)}',
              style: theme.textTheme.bodySmall?.copyWith(color: context.colors.success),
            ),
          ],
        ),
      );
    }
    return Row(
      children: <Widget>[
        Tooltip(
          message: requestOpen
              ? 'Wait for your teacher’s reply to your request first'
              : 'Confirm that you have checked your marks and agree with them',
          child: FilledButton.icon(
            key: const Key('verify'),
            onPressed: requestOpen ? null : onVerify,
            icon: const Icon(Icons.verified_outlined, size: 16),
            label: const Text('Verify my marks'),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            requestOpen
                ? 'A request is waiting for your teacher — verify once it is answered.'
                : 'When you have checked every question and your answer sheet, verify your marks.',
            style: context.text.caption,
          ),
        ),
      ],
    );
  }
}

/// Where a request stands, in words the student reads.
class _Status extends StatelessWidget {
  const _Status({required this.request});

  final CorrectionRequest request;

  @override
  Widget build(BuildContext context) {
    final (ToneKind tone, String text) = switch (request.status) {
      RequestStatus.open => (ToneKind.warning, 'Requested · waiting for your teacher'),
      RequestStatus.accepted => (
          ToneKind.success,
          'Accepted · ${formatMarks(request.oldMarks ?? 0)} → ${formatMarks(request.newMarks ?? 0)} marks'
              '${request.reply.isEmpty ? '' : ' — “${request.reply}”'}',
        ),
      RequestStatus.declined => (ToneKind.neutral, 'Declined — “${request.reply}”'),
    };
    return StatusPill(
      key: ValueKey<String>('request-status-${request.questionId}'),
      label: text,
      tone: tone,
      outlined: false,
      wrap: true,
    );
  }
}
