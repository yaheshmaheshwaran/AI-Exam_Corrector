import 'dart:async';
import 'dart:io';


import 'package:exam_corrector/core/errors/app_exception.dart';
import 'package:exam_corrector/domain/exam_document.dart';
import 'package:exam_corrector/domain/question_paper.dart';
import 'package:exam_corrector/marking/exam/answer_key.dart';
import 'package:exam_corrector/marking/exam/teacher_key/teacher_key.dart';
import 'package:exam_corrector/services/review/teacher_work_store.dart';
import 'package:exam_corrector/state/marked_script.dart';
import 'package:exam_corrector/features/workspace.dart';

/// The paper's answer key: the AI's, the teacher's own, and the teacher's
/// edits — and which marked scripts a change asks to re-mark.
mixin AnswerKeyFeature on Workspace {
  /// The teacher's own answer key for the chosen paper; null when they have
  /// not added one. Remembered per paper.
  TeacherKey? ownKey;
  bool _readingKey = false;

  /// The paper's questions, read ahead of marking so the teacher's key can
  /// be matched and reviewed before any script is marked.
  QuestionPaper? preparedPaper;

  TeacherKey? get teacherKey => ownKey;
  bool get isReadingKey => _readingKey;

  /// The paper's questions as read: from a marked script, or read ahead.
  QuestionPaper? get keyPaper => markedPaper ?? preparedPaper;

  /// How much of the paper the teacher's key covers, once it is matched.
  ({int covered, int total, int printed})? get keyCoverage {
    final TeacherKey? key = ownKey;
    final QuestionPaper? paper = keyPaper;
    if (key == null || !key.matched || paper == null) return null;
    return key.coverage(paper);
  }

  // --------------------------------------------------------------------------
  // Answer key
  // --------------------------------------------------------------------------

  /// The paper's answer key: the AI's as last prepared, the teacher's own,
  /// and their corrections; null when there is none of these.
  Future<AnswerKey?> answerKey() async {
    final SelectedDocument? paper = chosenPaper;
    if (paper == null) return null;
    try {
      final TeacherWorkStore work = TeacherWorkStore(pipelineOf().store);
      final Map<String, AnswerKeyEntry> entries = AnswerKey.entriesFromJson(await work.answerKey(paper.contentHash));
      final Map<String, String> edits = await work.answerKeyEdits(paper.contentHash);
      final AnswerKey key = AnswerKey(
        entries: entries,
        teacher: ownKey?.entries ?? const <String, TeacherKeyEntry>{},
        edits: edits,
      );
      return key.isEmpty ? null : key;
    } on IOException {
      return null;
    }
  }

  /// The paper's questions as read, for showing the key beside them.
  QuestionPaper? get markedPaper => scriptList
      .map((MarkedScript s) => s.assessment?.questionPaper)
      .nonNulls
      .firstOrNull;

  /// The teacher's own key for questions, in place of the AI's. It changes
  /// what the AI marks against, so marked scripts need re-marking.
  Future<void> saveAnswerKeyEdits(Map<String, String> edits, {bool? checked}) async {
    final SelectedDocument? paper = chosenPaper;
    if (paper == null) return;
    final AnswerKey? before = await answerKey();
    if (checked != null && before != null && checked != (aiKeyState?.checked ?? false)) {
      try {
        await TeacherWorkStore(pipelineOf().store)
            .saveAnswerKeyChecked(paper.contentHash, checked ? before.aiFingerprint : null);
      } on IOException catch (error) {
        fail('The answer key could not be saved.', '$error');
        return;
      }
      await refreshAiKey();
    }
    final Map<String, String> kept = <String, String>{
      for (final MapEntry<String, String> e in edits.entries)
        if (e.value.trim().isNotEmpty && e.value.trim() != (before?.baseTextFor(e.key) ?? '').trim())
          e.key: e.value.trim(),
    };
    try {
      await TeacherWorkStore(pipelineOf().store).saveAnswerKeyEdits(paper.contentHash, kept);
    } on IOException catch (error) {
      fail('The answer key could not be saved.', '$error');
      return;
    }
    final Set<String> changed = <String>{
      ...kept.keys,
      ...?before?.edits.keys,
    }.where((String id) => kept[id] != before?.edits[id]).toSet();
    if (changed.isEmpty) {
      setStatus(checked == true ? 'Answer key checked.' : 'Answer key unchanged.');
      return;
    }
    final int scripts = flagRemark();
    setStatus(scripts == 0
        ? 'Answer key saved.'
        : 'Answer key saved — ${changed.length} question${changed.length == 1 ? '' : 's'} changed. '
            '${afterKeyChange(scripts)}');
    await refreshAiKey();
    notifyListeners();
  }

  /// Marked scripts are now marked against an out-of-date key: flag them.
  /// During a run they are queued again, so it re-marks them before it ends.
  int flagRemark() {
    int scripts = 0;
    for (final MarkedScript script in scriptList) {
      if (script.result == null) continue;
      script.correctionsPending = true;
      runAttempted?.remove(script);
      scripts++;
    }
    return scripts;
  }

  /// What happens to [scripts] marked against a key that just changed: in
  /// the background they are re-marked by themselves; otherwise the teacher
  /// re-marks them.
  String afterKeyChange(int scripts) {
    if (scripts == 0) return '';
    final String n = '$scripts script${scripts == 1 ? '' : 's'}';
    if (!appConfig.backgroundProcessing) return 'Re-mark to apply it to $n.';
    if (isProcessing) return 'This run re-marks $n against it.';
    return startInBackground() ? 'Re-marking $n in the background.' : 'Re-mark to apply it to $n.';
  }


  /// Who wrote the AI's part of the key and whether the teacher has checked
  /// it; null when no question is marked against an AI key.
  ({String writer, bool checked})? get aiKeyStatus => aiKeyState;
  ({String writer, bool checked})? aiKeyState;

  @override
  Future<void> refreshAiKey() async {
    final SelectedDocument? paper = chosenPaper;
    ({String writer, bool checked})? next;
    try {
      final AnswerKey? key = paper == null ? null : await answerKey();
      if (paper != null && key != null && key.aiUsed.isNotEmpty) {
        final String? checked = await TeacherWorkStore(pipelineOf().store).answerKeyChecked(paper.contentHash);
        next = (writer: modelLabel(key.aiWriter), checked: checked == key.aiFingerprint);
      }
    } on IOException {
      next = aiKeyState;
    }
    if (next != aiKeyState) {
      aiKeyState = next;
      notifyListeners();
    }
  }

  @override
  Future<void> loadTeacherKey() async {
    final SelectedDocument? paper = chosenPaper;
    ownKey = null;
    preparedPaper = null;
    if (paper == null) return;
    try {
      ownKey = TeacherKey.fromJson(await TeacherWorkStore(pipelineOf().store).teacherKey(paper.contentHash));
    } on IOException {
      ownKey = null;
    }
    if (ownKey != null) await _readPaperAhead(paper);
  }

  /// Reads the paper's questions now, for the key; a paper that cannot be
  /// read yet — a scan with the recogniser unavailable — is read when
  /// marking starts instead.
  Future<QuestionPaper?> _readPaperAhead(SelectedDocument paper) async {
    try {
      preparedPaper = await pipelineOf().readQuestionPaper(paper);
    } on AppException {
      preparedPaper = null;
    }
    return preparedPaper;
  }

  /// Adds the teacher's own answer key for the chosen paper, or replaces it.
  /// It is matched to the paper's questions straight away when the paper can
  /// be read; questions it does not cover are marked as before.
  Future<void> chooseAnswerKey() async {
    final SelectedDocument? paper = chosenPaper;
    if (paper == null || isBusy || _readingKey) return;
    final String? path = await picker.pickAnswerKey();
    if (path == null) return;

    _readingKey = true;
    setStatus('Reading your answer key…');
    try {
      final TeacherKeySource source = await keyTextReader.readAnswerKey(path);
      final QuestionPaper? questions = await _readPaperAhead(paper);
      final TeacherKey key = questions == null
          ? source.unmatched
          : await pipelineOf().alignTeacherKey(questions, paper.contentHash, source, standard: paperStandard);
      await TeacherWorkStore(pipelineOf().store).saveTeacherKey(paper.contentHash, key.toJson());
      final bool changed = ownKey?.sourceHash != key.sourceHash;
      ownKey = key;
      final int scripts = changed ? flagRemark() : 0;
      final ({int covered, int total, int printed})? coverage = keyCoverage;
      setStatus(<String>[
        if (coverage == null)
          'Answer key added. It will be matched to the questions when marking starts.'
        else
          'Answer key added: it covers ${coverage.covered} of ${coverage.total} questions; the rest are marked as usual.',
        if (scripts > 0) afterKeyChange(scripts),
      ].join(' '));
      unawaited(refreshAiKey());
    } on AppException catch (error) {
      fail('The answer key could not be used.', error.message);
    } on IOException catch (error) {
      fail('The answer key could not be saved.', '$error');
    } finally {
      _readingKey = false;
      notifyListeners();
    }
  }

  /// Removes the teacher's answer key: the paper is marked as it was before.
  Future<void> removeAnswerKey() async {
    final SelectedDocument? paper = chosenPaper;
    if (paper == null || ownKey == null || isBusy) return;
    try {
      await TeacherWorkStore(pipelineOf().store).removeTeacherKey(paper.contentHash);
    } on IOException catch (error) {
      fail('The answer key could not be removed.', '$error');
      return;
    }
    ownKey = null;
    final int scripts = flagRemark();
    setStatus(scripts == 0 ? 'Answer key removed.' : 'Answer key removed. ${afterKeyChange(scripts)}');
    unawaited(refreshAiKey());
    notifyListeners();
  }
}
