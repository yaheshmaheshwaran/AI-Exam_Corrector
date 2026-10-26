import 'dart:async';
import 'dart:io';


import 'package:exam_corrector/core/async/cancellation.dart';
import 'package:exam_corrector/core/errors/app_exception.dart';
import 'package:exam_corrector/domain/exam_document.dart';
import 'package:exam_corrector/domain/marking_standard.dart';
import 'package:exam_corrector/domain/student_answer.dart';
import 'package:exam_corrector/services/review/marking_standard_store.dart';
import 'package:exam_corrector/state/marked_script.dart';
import 'package:exam_corrector/features/workspace.dart';

/// The marking standard the chosen paper is marked to.
mixin StandardFeature on Workspace {
  // --------------------------------------------------------------------------
  // Marking standard
  // --------------------------------------------------------------------------

  /// Sets the chosen paper's marking standard, and saves it — as the default
  /// for new papers too when asked.
  ///
  /// A change of level or of the written college rules changes how the AI
  /// judges, so the marked scripts are left to re-mark, with an estimate of
  /// the requests it takes. A change of rounding, mark step or penalty is
  /// arithmetic on marks already made: it is applied at once, from the
  /// cache, with no request at all.
  Future<void> setMarkingStandard(MarkingStandard next, {bool asDefault = false}) async {
    if (isBusy) return;
    final MarkingStandard previous = paperStandard;
    paperStandard = next;
    final SelectedDocument? paper = chosenPaper;
    final MarkingStandardStore? standards = standardsStore;
    if (paper != null && standards != null) {
      try {
        await standards.save(paper.contentHash, next, asDefault: asDefault);
      } on IOException catch (error) {
        fail('The marking standard could not be saved.', '$error');
      }
    }

    final List<MarkedScript> marked =
        scriptList.where((MarkedScript s) => s.result != null).toList();
    if (marked.isEmpty) {
      setStatus('Marking standard: ${next.summary}.');
      return;
    }

    if (next.judgementKey != previous.judgementKey) {
      int questions = 0;
      int requests = 0;
      for (final MarkedScript script in marked) {
        final int answered = script.assessment!.answers.values
            .where((StudentAnswer a) => !a.isEmpty)
            .length;
        questions += answered;
        requests += (answered / markingSettings.limitsForChain(markersInUse).questionsPerRequest).ceil();
        script.correctionsPending = true;
      }
      setStatus('Marking standard: ${next.summary}. The AI judges differently at '
          'this level — re-mark to apply it: $questions answer${questions == 1 ? '' : 's'}, '
          'about $requests request${requests == 1 ? '' : 's'}.');
      return;
    }

    // Arithmetic only: every mark comes back from the cache.
    await rerunFromCache('Marking standard applied: ${next.summary} — no re-marking needed.');
  }

  /// Runs every marked script again with every mark from the cache, for a
  /// change that is arithmetic on the marks.
  @override
  Future<void> rerunFromCache(String done) async {
    final List<MarkedScript> marked =
        scriptList.where((MarkedScript s) => s.result != null).toList();
    if (marked.isEmpty) {
      setStatus(done);
      return;
    }
    final CancellationToken token = CancellationToken();
    runToken = token;
    try {
      for (final MarkedScript script in marked) {
        await runScript(script, token);
      }
      setStatus(done);
    } on CancelledException {
      setStatus('Cancelled.');
    } finally {
      runToken = null;
      notifyListeners();
    }
  }
}
