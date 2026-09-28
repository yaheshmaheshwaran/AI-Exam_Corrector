part of 'home_screen.dart';

/// Where a script is published: the student's roll number, the subject and
/// the exam — what the student signs in with.
class _PublishDialog extends StatefulWidget {
  const _PublishDialog({
    required this.fileName,
    required this.rollNo,
    required this.subjectCode,
    required this.exam,
    this.registered,
  });

  final String fileName;
  final String rollNo;
  final String subjectCode;
  final String exam;

  /// The college's signed-up roll numbers, to say when a roll has no account
  /// yet; null when that cannot be known.
  final Future<Set<String>?>? registered;

  @override
  State<_PublishDialog> createState() => _PublishDialogState();
}

class _PublishDialogState extends State<_PublishDialog> {
  late final TextEditingController _roll = TextEditingController(text: widget.rollNo);
  final TextEditingController _name = TextEditingController();
  late final TextEditingController _subject = TextEditingController(text: widget.subjectCode);
  late final TextEditingController _exam = TextEditingController(text: widget.exam);
  Set<String>? _registered;

  @override
  void initState() {
    super.initState();
    widget.registered?.then((Set<String>? rolls) {
      if (mounted) setState(() => _registered = rolls);
    });
  }

  /// A roll number no student has signed up with yet: publishing still
  /// works, and they see it once they do.
  bool get _unregistered {
    final Set<String>? registered = _registered;
    final String roll = PublishedResult.normaliseRoll(_roll.text);
    return registered != null && roll.isNotEmpty && !registered.contains(roll);
  }

  @override
  void dispose() {
    for (final TextEditingController c in <TextEditingController>[_roll, _name, _subject, _exam]) {
      c.dispose();
    }
    super.dispose();
  }

  bool get _ready => _roll.text.trim().isNotEmpty && _subject.text.trim().isNotEmpty;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Publish to the student'),
      content: SizedBox(
        width: 460,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Text('${widget.fileName}. The student sees the final marks, section totals, '
                'each question’s explanation and your comments, and can ask you to look '
                'again at a mark.'),
            const SizedBox(height: 12),
            TextField(
              key: const Key('publish-roll'),
              controller: _roll,
              autofocus: widget.rollNo.isEmpty,
              onChanged: (_) => setState(() {}),
              decoration: const InputDecoration(labelText: 'Roll number *'),
            ),
            if (_unregistered) ...<Widget>[
              const SizedBox(height: 8),
              InfoBanner(
                key: const Key('publish-roll-unregistered'),
                title: 'No student has signed up with ${PublishedResult.normaliseRoll(_roll.text)} yet',
                body: 'You can still publish: they will see it as soon as they sign up with that roll number.',
                tone: ToneKind.warning,
                margin: EdgeInsets.zero,
              ),
            ],
            const SizedBox(height: 8),
            TextField(
              key: const Key('publish-name'),
              controller: _name,
              decoration: const InputDecoration(labelText: 'Student name (optional)'),
            ),
            const SizedBox(height: 8),
            Row(
              children: <Widget>[
                Expanded(
                  child: TextField(
                    key: const Key('publish-subject'),
                    controller: _subject,
                    onChanged: (_) => setState(() {}),
                    decoration: const InputDecoration(labelText: 'Subject code *', hintText: 'CCS356'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: TextField(
                    key: const Key('publish-exam'),
                    controller: _exam,
                    decoration: const InputDecoration(labelText: 'Exam', hintText: 'CAT 1'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
      actions: <Widget>[
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
        FilledButton(
          key: const Key('publish-confirm'),
          onPressed: _ready
              ? () => Navigator.of(context).pop((
                    rollNo: _roll.text,
                    student: _name.text,
                    subjectCode: _subject.text,
                    exam: _exam.text,
                  ))
              : null,
          child: const Text('Publish'),
        ),
      ],
    );
  }
}

/// A class published at once: one subject and exam, each script's roll
/// number found in its file name or typed in.
class _PublishClassDialog extends StatefulWidget {
  const _PublishClassDialog({required this.scripts, required this.subjectCode, required this.exam});

  final List<MarkedScript> scripts;
  final String subjectCode;
  final String exam;

  @override
  State<_PublishClassDialog> createState() => _PublishClassDialogState();
}

class _PublishClassDialogState extends State<_PublishClassDialog> {
  late final TextEditingController _subject = TextEditingController(text: widget.subjectCode);
  late final TextEditingController _exam = TextEditingController(text: widget.exam);
  late final Map<int, TextEditingController> _rolls = <int, TextEditingController>{
    for (int i = 0; i < widget.scripts.length; i++)
      if (widget.scripts[i].result != null)
        i: TextEditingController(
          text: PublishedResult.rollFromFileName(widget.scripts[i].document.fileName) ?? '',
        ),
  };

  @override
  void dispose() {
    _subject.dispose();
    _exam.dispose();
    for (final TextEditingController c in _rolls.values) {
      c.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Publish the class to students'),
      content: SizedBox(
        width: 560,
        height: 440,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Row(
              children: <Widget>[
                Expanded(
                  child: TextField(
                    key: const Key('class-subject'),
                    controller: _subject,
                    onChanged: (_) => setState(() {}),
                    decoration: const InputDecoration(labelText: 'Subject code *'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: TextField(controller: _exam, decoration: const InputDecoration(labelText: 'Exam')),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Text('Roll number for each script — scripts left blank are not published.',
                style: context.text.caption),
            const SizedBox(height: 6),
            Expanded(
              child: ListView(
                children: <Widget>[
                  for (final MapEntry<int, TextEditingController> entry in _rolls.entries)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 6),
                      child: Row(
                        children: <Widget>[
                          Expanded(
                            child: Text(widget.scripts[entry.key].document.fileName,
                                overflow: TextOverflow.ellipsis),
                          ),
                          const SizedBox(width: 8),
                          SizedBox(
                            width: 160,
                            child: TextField(
                              controller: entry.value,
                              decoration: const InputDecoration(isDense: true, hintText: 'Roll number'),
                            ),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
      actions: <Widget>[
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
        FilledButton(
          key: const Key('class-publish-confirm'),
          onPressed: _subject.text.trim().isEmpty
              ? null
              : () => Navigator.of(context).pop((
                    subjectCode: _subject.text,
                    exam: _exam.text,
                    rollNos: <int, String>{
                      for (final MapEntry<int, TextEditingController> e in _rolls.entries) e.key: e.value.text,
                    },
                  )),
          child: const Text('Publish'),
        ),
      ],
    );
  }
}

