import 'dart:async';
import 'dart:io';


import 'package:exam_corrector/core/errors/app_exception.dart';
import 'package:exam_corrector/domain/exam_document.dart';
import 'package:exam_corrector/domain/marking_standard.dart';
import 'package:exam_corrector/domain/processing_job.dart';
import 'package:exam_corrector/domain/teacher_review.dart';
import 'package:exam_corrector/models/marking_guidance.dart';
import 'package:exam_corrector/services/review/marking_standard_store.dart';
import 'package:exam_corrector/services/review/teacher_work_store.dart';
import 'package:exam_corrector/state/marked_script.dart';
import 'package:exam_corrector/features/workspace.dart';

/// Choosing the student scripts and the question paper, moving between
/// scripts, the teacher's guidance, and the work saved for each script.
mixin InputsFeature on Workspace {
  // --------------------------------------------------------------------------
  // Inputs
  // --------------------------------------------------------------------------

  /// Chooses the student scripts to mark — one, or a whole class at once —
  /// replacing any chosen before.
  Future<void> chooseAnswerSheet() async {
    if (isBusy) return;
    final List<String> paths = await picker.pickDocuments();
    if (paths.isEmpty) return;
    await _addScripts(paths, replace: true);
  }

  /// Adds more scripts to the class set — also while a background run is
  /// going, when they join its queue.
  Future<void> addAnswerSheets() async {
    if (choosing || (isProcessing && !backgroundRun)) return;
    final List<String> paths = await picker.pickDocuments();
    if (paths.isEmpty) return;
    await _addScripts(paths, replace: false);
  }

  Future<void> _addScripts(List<String> paths, {required bool replace}) async {
    choosing = true;
    setStatus(paths.length == 1
        ? 'Checking the answer sheet…'
        : 'Checking ${paths.length} answer sheets…');

    final List<MarkedScript> added = <MarkedScript>[];
    final List<String> failures = <String>[];
    for (final String path in paths) {
      try {
        final SelectedDocument document =
            await documentInspector.inspect(path, DocumentRole.answerSheet);
        final bool duplicate = <MarkedScript>[
          if (!replace) ...scriptList,
          ...added,
        ].any((MarkedScript s) => s.document.contentHash == document.contentHash);
        if (!duplicate) added.add(MarkedScript(document));
      } on AppException catch (error) {
        failures.add(paths.length == 1
            ? error.message
            : '${path.split(RegExp(r'[/\\]')).last}: ${error.message}');
      }
    }

    try {
      if (replace && (added.isNotEmpty || paths.length == 1)) {
        scriptList
          ..clear()
          ..addAll(added);
        shownIndex = 0;
        currentJob = null;
      } else {
        scriptList.addAll(added);
      }
      classShown = scriptList.length > 1;
      for (final MarkedScript script in added) {
        await loadSavedWork(script);
      }

      if (failures.isNotEmpty) {
        fail(
          paths.length == 1
              ? 'The answer sheet could not be read.'
              : '${failures.length} of ${paths.length} answer sheets could not be read.',
          failures.join('\n'),
        );
      } else if (isProcessing) {
        setStatus('${added.length} answer sheet${added.length == 1 ? '' : 's'} added to the queue.');
      } else if (scriptList.length == 1) {
        setStatus('Answer sheet ready: ${describe(scriptList.single.document)}.');
      } else {
        setStatus('${scriptList.length} answer sheets ready to mark as a class.');
      }
      if (scriptList.length == 1 && !isProcessing) await loadResumable();
    } finally {
      choosing = false;
      notifyListeners();
    }
    startInBackground();
  }

  Future<void> chooseQuestionPaper() async {
    if (isBusy) return;
    final String? path = await picker.pickDocument();
    if (path == null) return;

    choosing = true;
    setStatus('Checking the question paper…');
    try {
      chosenPaper = await documentInspector.inspect(path, DocumentRole.questionPaper);
      // A different paper means every mark so far was against the wrong
      // questions.
      for (final MarkedScript script in scriptList) {
        script.assessment = null;
        script.error = null;
      }
      currentJob = null;
      setStatus('Question paper ready: ${describe(chosenPaper!)}.');
      await prepareSyllabus(chosenPaper!);
      final MarkingStandardStore? standards = standardsStore;
      if (standards != null) {
        try {
          paperStandard = await standards.forPaper(chosenPaper!.contentHash);
        } on IOException {
          paperStandard = const MarkingStandard();
        }
      }
      await loadModeration();
      for (final MarkedScript script in scriptList) {
        await loadSavedWork(script);
      }
      await loadResumable();
      await loadTeacherKey();
      await refreshAiKey();
    } on AppException catch (error) {
      chosenPaper = null;
      fail('The question paper could not be read.', error.message);
    } finally {
      choosing = false;
      notifyListeners();
    }
    startInBackground();
  }



  /// Opens one student's results.
  void openScript(int index) {
    if (index < 0 || index >= scriptList.length) return;
    shownIndex = index;
    classShown = false;
    notifyListeners();
  }

  /// Back to the class table.
  void showClass() {
    if (!isClass) return;
    classShown = true;
    notifyListeners();
  }

  void removeScript(int index) {
    if (isBusy || index < 0 || index >= scriptList.length) return;
    scriptList.removeAt(index);
    shownIndex = shownIndex.clamp(0, scriptList.isEmpty ? 0 : scriptList.length - 1);
    if (scriptList.length <= 1) classShown = false;
    notifyListeners();
  }

  /// Picks up the teacher's earlier work on a script: its corrections and,
  /// with a question paper chosen, its reviews.
  @override
  Future<void> loadSavedWork(MarkedScript script) async {
    final SelectedDocument? paper = chosenPaper;
    try {
      final TeacherWorkStore work = TeacherWorkStore(pipelineOf().store);
      script.transcriptions = await work.transcriptions(script.document.contentHash);
      script.reviews = paper == null
          ? const TeacherReviewBook()
          : await work.reviews(script.document.contentHash, paper.contentHash);
      script.assignments = paper == null
          ? const <String, String>{}
          : await work.assignments(script.document.contentHash, paper.contentHash);
    } on IOException {
      // Saved work is a convenience; its absence is not an error.
    }
  }

  /// An unfinished run of a single script against this paper, to resume.
  @override
  Future<void> loadResumable() async {
    resumable = null;
    final SelectedDocument? paper = chosenPaper;
    if (scriptList.length != 1 || paper == null) return;
    try {
      final ProcessingJob? last = await pipelineOf().lastJob(scriptList.single.document, paper);
      if (last != null &&
          (last.stage == ProcessingStage.failed ||
              last.stage == ProcessingStage.cancelled)) {
        resumable = last;
        setStatus(
          'An unfinished run of these papers was found — marking will resume '
          'from ${(last.failedStage ?? ProcessingStage.rendering).label.toLowerCase()}.',
        );
      }
    } on IOException {
      // As above.
    }
  }


  /// The teacher's optional marking notes. Notifies only when it changes
  /// between empty and not, so typing does not rebuild the results.
  void setGuidance(String text) {
    final bool wasEmpty = chosenGuidance.isEmpty;
    chosenGuidance = MarkingGuidance(text);
    if (wasEmpty != chosenGuidance.isEmpty) notifyListeners();
  }

  void clearGuidance() {
    if (isBusy) return;
    chosenGuidance = const MarkingGuidance.none();
    chosenGuidanceFile = null;
    notifyListeners();
  }

  /// Loads marking guidance from a text, Markdown or PDF file.
  Future<void> loadGuidanceFile() async {
    if (isBusy) return;
    final String? path = await picker.pickGuidance();
    if (path == null) return;
    try {
      final String text = path.toLowerCase().endsWith('.pdf')
          ? await pdfReader.extractText(path)
          : await File(path).readAsString();
      chosenGuidance = MarkingGuidance(
        text.split('\n').where((String l) => !l.startsWith('--- Page ')).join('\n').trim(),
      );
      chosenGuidanceFile = path.split(RegExp(r'[/\\]')).last;
      setStatus('Marking guidance loaded from $chosenGuidanceFile.');
    } on AppException catch (error) {
      fail('The guidance file could not be read.', error.message);
    } on IOException catch (error) {
      fail('The guidance file could not be read.', '$error');
    }
  }
}
