import 'dart:async';


import 'package:exam_corrector/core/async/cancellation.dart';
import 'package:exam_corrector/ai/providers.dart';
import 'package:exam_corrector/ai/usage.dart';
import 'package:exam_corrector/core/errors/app_exception.dart';
import 'package:exam_corrector/core/utils/duration_format.dart';
import 'package:exam_corrector/core/utils/marks_format.dart';
import 'package:exam_corrector/domain/exam_assessment.dart';
import 'package:exam_corrector/domain/exam_document.dart';
import 'package:exam_corrector/domain/processing_job.dart';
import 'package:exam_corrector/models/correction_result.dart';
import 'package:exam_corrector/state/marked_script.dart';
import 'package:exam_corrector/features/workspace.dart';

/// Marking: one script or a whole class, in the background when chosen, and
/// what happens when a marking model runs out of its allowance.
mixin MarkingRunFeature on Workspace {
  DateTime? runStart;
  ({Duration took, int scripts})? previousRun;

  /// When the run under way began — one script, or a whole class marked
  /// together; null when nothing is being marked.
  DateTime? get runStartedAt => runStart;

  /// How long the last run took and how many scripts it marked; null
  /// before the first.
  ({Duration took, int scripts})? get lastRun => previousRun;

  /// How long the run under way has taken so far; zero between runs.
  Duration get runTime => runStart == null ? Duration.zero : clockNow().difference(runStart!);

  Timer? resumeTimer;
  DateTime? resumeTime;

  /// When a class paused for quota will carry on by itself, if it will.
  DateTime? get resumeAt => resumeTime;

  // --------------------------------------------------------------------------
  // Processing
  // --------------------------------------------------------------------------

  /// Understands the current script and marks it against the question paper.
  ///
  /// Also how the teacher re-marks after correcting a transcription: every
  /// stage whose inputs did not change comes straight from the cache.
  /// Marks the open script. When Gemini marks and its quota has run out, the
  /// open model marks it instead — every mark flagged for review.
  Future<void> startCorrection() async {
    if (isBusy) return;
    final MarkedScript? script = currentScript;
    if (!readyToMark(script == null ? const <MarkedScript>[] : <MarkedScript>[script])) {
      return;
    }

    final CancellationToken token = CancellationToken();
    runToken = token;
    runStart = clockNow();
    resumable = null;
    setStatus('Starting…');
    bool marked = false;
    try {
      ExamAssessment? assessment = await runScript(script!, token);
      String? openFailure;
      if (assessment != null && assessment.result == null && firstMarkerOut) {
        setStatus(_handOffMessage());
        final ExamAssessment? handed = await runScript(script, token, backup: true);
        if (handed?.result != null) {
          assessment = handed;
        } else {
          openFailure = handed?.job.error ?? script.error;
        }
      }
      final CorrectionResult? result = assessment?.result;
      if (assessment == null) return;
      if (result == null) {
        final ({bool all, DateTime until})? quota = markingQuota();
        final DateTime? back = quota != null && quota.all ? quota.until : null;
        fail(
          back == null
              ? 'Marking stopped — everything read from the paper was kept.'
              : 'Read in full. Marking waits for quota until ${clockText(back)}.',
          back == null
              ? assessment.job.error ?? 'Marking failed.'
              : 'Everything on the paper has been read and kept. The marking models '
                  'are out of quota until ${clockText(back)}; mark again then.'
                  '${_openCouldNot(openFailure)}',
        );
      } else {
        marked = true;
        setStatus('${summarise(result)} Took ${formatElapsed(runTime)}.');
      }
    } on CancelledException {
      setStatus('Cancelled after ${formatElapsed(runTime)}. Starting again resumes where it stopped.');
    } finally {
      previousRun = (took: runTime, scripts: marked ? 1 : 0);
      runStart = null;
      runToken = null;
      notifyListeners();
    }
  }

  /// Marks every script in the class that still needs it, one after another.
  ///
  /// Scripts already marked are not repeated; a stopped batch resumes where
  /// it stopped, because every finished stage is cached. A marking failure —
  /// most often a spent quota — stops the batch rather than failing the same
  /// way for every remaining student.
  ///
  /// When Gemini marks and every Gemini marking model runs out of quota,
  /// the open model marks the rest of the class — whole scripts, every mark
  /// flagged for review — rather than the class waiting for the reset.
  /// Every script is still read in full when marking has to wait.
  Future<void> markAll() async {
    if (isBusy) return;
    if (!readyToMark(scriptList)) return;

    if (!scriptList.any((MarkedScript s) => s.needsWork)) {
      setStatus('Every script is already marked.');
      return;
    }

    resumeTimer?.cancel();
    resumeTimer = null;
    resumeTime = null;

    final CancellationToken token = CancellationToken();
    runToken = token;
    runStart = clockNow();
    backgroundRun = appConfig.backgroundProcessing;
    final bool background = backgroundRun;
    if (background) {
      classShown = true;
      unawaited(backgroundSignals.keepAwake(true));
      unawaited(backgroundSignals.badge(_progressBadge));
    }
    int done = 0;
    // Scripts this run has taken up. The queue is read afresh after each one,
    // so scripts added while it runs join it.
    final Set<MarkedScript> attempted = runAttempted = <MarkedScript>{};
    MarkedScript? nextScript({MarkedScript? after}) {
      for (final MarkedScript s in scriptList) {
        if (s.needsWork && !attempted.contains(s) && !identical(s, after)) return s;
      }
      return null;
    }

    // Set once Gemini runs out: the rest of the class goes to the open model.
    bool backup = false;
    // Why the open model could not take over, when it could not.
    String? openFailure;
    // Scripts whose own marker ran out of quota; the rest of the class goes
    // on with another marking model.
    final List<MarkedScript> waiting = <MarkedScript>[];
    // The next script is read while this one is being marked: marking waits
    // on the network, reading works this computer, so the two overlap.
    final Map<MarkedScript, Future<void>> prefetched = <MarkedScript, Future<void>>{};
    try {
      for (MarkedScript? script = nextScript(); script != null; script = nextScript()) {
        attempted.add(script);
        final MarkedScript? following = nextScript(after: script);
        // Never two runs of one script at once: its prefetch finishes first.
        await prefetched.remove(script);
        batchIndex = scriptList.indexOf(script) + 1;
        setStatus('Script $batchIndex of ${scriptList.length}: ${script.document.fileName}…');
        void onMarking() {
          if (following != null) prefetched.putIfAbsent(following, () => readAhead(following, token));
        }

        ExamAssessment? assessment = await runScript(script, token, backup: backup, onMarking: onMarking);
        if (!backup && openFailure == null && assessment != null && assessment.result == null && firstMarkerOut) {
          setStatus(_handOffMessage());
          final ExamAssessment? handed = await runScript(script, token, backup: true, onMarking: onMarking);
          if (handed?.result != null) {
            backup = true;
            assessment = handed;
          } else {
            // The open model cannot take over either: the class waits for
            // Gemini, as it would with no open model at all.
            openFailure = handed?.job.error ?? script.error ?? 'It could not be reached.';
          }
        }
        if (assessment == null) {
          fail(
            'Stopped at ${script.document.fileName}.',
            '${script.document.fileName}: ${script.error}\n\nThe scripts marked so far '
                'are kept. Marking all again continues from this one.',
          );
          return;
        }
        if (assessment.result == null) {
          final ({bool all, DateTime until})? quota = backup ? null : markingQuota();
          if (quota != null && !quota.all) {
            waiting.add(script);
            continue;
          }
          if (quota != null) {
            // Marking must wait; scanning need not. Every script left is read
            // now, so marking them later is quick.
            final List<MarkedScript> rest = <MarkedScript>[
              for (final MarkedScript s in scriptList)
                if (s.needsWork && !attempted.contains(s)) s,
            ];
            for (int j = 0; j < rest.length; j++) {
              setStatus('Reading ${rest[j].document.fileName} (${j + 1} of ${rest.length}) '
                  'while marking waits for quota…');
              await (prefetched.remove(rest[j]) ?? readAhead(rest[j], token));
            }
            token.throwIfCancelled();
            _scheduleResume(quota.until);
            fail(
              'Every script read. Marking resumes at ${clockText(quota.until)}.',
              'Every marking model is out of quota until ${clockText(quota.until)}. All '
                  '${rest.length + 1} unmarked script${rest.isEmpty ? ' has' : 's have'} been read '
                  'and kept, and marking carries on by itself then while Marklume stays '
                  'open — or press Mark all after that time.${_openCouldNot(openFailure)}',
            );
            return;
          }
          fail(
            'Marking stopped at ${script.document.fileName}.',
            '${assessment.job.error ?? 'Marking failed.'}\n\nThe scripts marked so '
                'far are kept, and everything read from this one. Marking all '
                'again continues from here.',
          );
          return;
        }
        done++;
        if (background) unawaited(backgroundSignals.badge(_progressBadge));
      }
      // Scripts left waiting for a Gemini model that began them are marked
      // afresh by the open model once Gemini is out altogether.
      if (backup) {
        for (final MarkedScript script in List<MarkedScript>.of(waiting)) {
          batchIndex = scriptList.indexOf(script) + 1;
          final ExamAssessment? assessment = await runScript(script, token, backup: true);
          if (assessment?.result != null) {
            waiting.remove(script);
            done++;
          }
        }
      }
      final int review = scriptList
          .where((MarkedScript s) => s.status == ScriptStatus.reviewRequired)
          .length;
      final ({bool all, DateTime until})? quota = waiting.isEmpty ? null : markingQuota();
      if (quota != null) _scheduleResume(quota.until);
      setStatus('Marked $done script${done == 1 ? '' : 's'} in ${formatElapsed(runTime)}. '
          '${review == 0 ? 'Nothing needs review.' : '$review need your review.'}'
          '${waiting.isEmpty ? '' : ' ${waiting.length} wait${waiting.length == 1 ? 's' : ''} for the '
              'model that began marking ${waiting.length == 1 ? 'it' : 'them'}'
              '${quota == null ? '.' : ' and carr${waiting.length == 1 ? 'ies' : 'y'} on by itself at ${clockText(quota.until)}.'}'}');
    } on CancelledException {
      setStatus('Cancelled after $done script${done == 1 ? '' : 's'} (${formatElapsed(runTime)}). '
          'Marking all again continues where it stopped.');
    } finally {
      // A prefetch still running when the batch stops is left to finish into
      // the cache, or to stop at the cancellation.
      await Future.wait(prefetched.values);
      previousRun = (took: runTime, scripts: done);
      runStart = null;
      runToken = null;
      batchIndex = null;
      backgroundRun = false;
      runAttempted = null;
      classShown = isClass;
      notifyListeners();
      if (background) {
        unawaited(backgroundSignals.keepAwake(false));
        unawaited(backgroundSignals.badge(null));
        unawaited(backgroundSignals.notify(
          statusError ? 'Marking stopped' : 'Class marked',
          statusText,
        ));
      }
    }
  }

  /// How many of the class's scripts are marked.
  int get markedCount => scriptList.where((MarkedScript s) => !s.needsWork).length;

  /// Which model marks now, in the teacher's words: the first choice, or the
  /// backup while the first is out of its allowance.
  String get engineLabel {
    final List<String> markers = markersInUse;
    if (markers.isEmpty) return '';
    final bool firstOut = usage?.isExhausted(markers.first) ?? false;
    final String model = firstOut && markers.length > 1 ? markers[1] : markers.first;
    final ModelProvider? provider = aiSettings.providers.of(model);
    if (provider != null && provider.selfHosted && (health?.isDown(provider.id) ?? false)) {
      return '${provider.label} down';
    }
    return provider?.label ?? model;
  }


  /// "Marked of all" for the app's icon during a background run.
  String get _progressBadge =>
      '${scriptList.where((MarkedScript s) => !s.needsWork).length}/${scriptList.length}';


  /// With background processing on, starts marking the class as soon as it
  /// can: scripts and a question paper chosen, something left to mark, a
  /// model set up. Never raises an error — a class that is not ready simply
  /// does not start.
  /// Whether a run started.
  @override
  bool startInBackground() {
    if (!appConfig.backgroundProcessing || isBusy) return false;
    final SelectedDocument? paper = chosenPaper;
    if (paper == null || scriptList.isEmpty || !aiSettings.hasModelAccess) return false;
    if (!scriptList.any((MarkedScript s) => s.needsWork)) return false;
    if (scriptList.any((MarkedScript s) => s.document.contentHash == paper.contentHash)) return false;
    unawaited(markAll());
    return true;
  }

  /// Checks what every run needs, raising the reason when something is
  /// missing.
  bool readyToMark(List<MarkedScript> scripts) {
    final SelectedDocument? paper = chosenPaper;
    if (scripts.isEmpty) {
      raiseError("Choose the student's answer sheet first.");
      return false;
    }
    if (paper == null) {
      raiseError(
        'Choose the question paper. It is what establishes the questions and '
        'how many marks each is worth.',
      );
      return false;
    }
    for (final MarkedScript script in scripts) {
      if (script.document.contentHash == paper.contentHash) {
        raiseError(
          'The answer sheet and the question paper are the same document '
          '("${script.document.fileName}"). Choose the student\'s completed '
          'script as the answer sheet, and the question paper — with or without '
          'its mark scheme — as the question paper.',
        );
        return false;
      }
    }
    return true;
  }

  /// Runs the pipeline for one script. Returns null when a stage before
  /// marking failed, with the reason recorded on the script; rethrows a
  /// cancellation.
  /// Reads [script] up to marking, quietly, into the cache. Any failure is
  /// left for the script's own run to meet and report.
  Future<void> readAhead(MarkedScript script, CancellationToken token) async {
    try {
      await pipelineOf().run(
        answerSheet: script.document,
        questionPaper: chosenPaper!,
        guidance: chosenGuidance.trimmed,
        teacherTranscriptions: script.transcriptions,
        teacherAssignments: script.assignments,
        syllabi: savedSyllabi,
        syllabusChoice: chosenSyllabus,
        standard: paperStandard,
        moderation: appliedModeration,
        cancel: token,
        prepareOnly: true,
      );
    } on Object {
      // Reported by the real run.
    }
  }

  @override
  Future<ExamAssessment?> runScript(
    MarkedScript script,
    CancellationToken token, {
    bool backup = false,
    void Function()? onMarking,
  }) async {
    script.processing = true;
    script.error = null;
    try {
      // A GPU server that stopped earlier may be back: check before this
      // script starts, never in the middle of one.
      await health?.recheck(aiSettings);
      final ExamAssessment assessment = await pipelineOf().run(
        answerSheet: script.document,
        questionPaper: chosenPaper!,
        guidance: chosenGuidance.trimmed,
        teacherTranscriptions: script.transcriptions,
        teacherAssignments: script.assignments,
        syllabi: savedSyllabi,
        syllabusChoice: chosenSyllabus,
        standard: paperStandard,
        moderation: appliedModeration,
        cancel: token,
        backup: backup,
        onUpdate: (ProcessingJob job) {
          if (job.stage == ProcessingStage.marking) onMarking?.call();
          final ProcessingJob? previous = currentJob;
          currentJob = job;
          statusText = batchIndex == null
              ? job.message
              : 'Script $batchIndex of ${scriptList.length}: ${job.message}';
          statusError = false;
          // Within a stage only the progress moves, and only the widgets
          // showing it need to hear; a new job or stage changes what the
          // window shows.
          if (previous == null || previous.jobId != job.jobId || previous.stage != job.stage) {
            notifyListeners();
          } else {
            progressPulse.pulse();
          }
        },
      );
      script.assessment = assessment;
      currentJob = assessment.job;
      script.correctionsPending = false;
      if (assessment.result == null) script.error = assessment.job.error;
      return assessment;
    } on CancelledException {
      rethrow;
    } on AppException catch (error) {
      script.error = error.message;
      if (batchIndex == null) fail('Correction failed.', error.message);
      return null;
    } catch (error) {
      // A pipeline failure must never take the application down.
      script.error = 'Unexpected error during correction: $error';
      if (batchIndex == null) fail('Correction failed.', script.error!);
      return null;
    } finally {
      script.processing = false;
      // The first script to reach marking prepares the AI's key.
      unawaited(refreshAiKey());
    }
  }

  /// Whether the first-choice marker is out of its allowance and a backup
  /// marker is set up to take over.
  bool get firstMarkerOut {
    if (markersInUse.length < 2) return false;
    final UsageMonitor? usage = this.usage;
    return usage != null && usage.isExhausted(markersInUse.first);
  }

  /// Why marking waits although a backup marker is set up.
  String _openCouldNot(String? failure) => failure == null || markersInUse.length < 2
      ? ''
      : '\n\nThe backup marker (${markersInUse[1]}) could not take over: $failure';

  String _handOffMessage() {
    final DateTime? back = usage?.exhaustedUntil(markersInUse.first);
    return '${modelLabel(markersInUse.first)} is out of its allowance${back == null ? '' : ' until ${clockText(back)}'} — '
        'marking with ${modelLabel(markersInUse[1])} instead; every mark is flagged for your review.';
  }

  /// When the marking models come back, if every one of them is out of its
  /// allowance now.
  DateTime? get markingBackAt {
    final ({bool all, DateTime until})? quota = markingQuota();
    return quota != null && quota.all ? quota.until : null;
  }

  /// Whether marking stopped because marking models ran out of allowance:
  /// [all] of them, or only some — such as the one a script began with — and
  /// when the first comes back. Null when no marking model is out.
  ({bool all, DateTime until})? markingQuota() {
    final UsageMonitor? usage = this.usage;
    if (usage == null) return null;
    final List<String> chain = markersInUse;
    final List<DateTime> back = <DateTime>[
      for (final String model in chain)
        if (usage.exhaustedUntil(model) case final DateTime until) until,
    ];
    if (back.isEmpty) return null;
    back.sort();
    return (all: back.length == chain.length, until: back.first);
  }


  /// Marks the class again once quota is back, while the app stays open.
  void _scheduleResume(DateTime until) {
    resumeTimer?.cancel();
    final Duration wait = until.difference(DateTime.now()) + const Duration(minutes: 1);
    resumeTime = until;
    resumeTimer = Timer(wait.isNegative ? const Duration(minutes: 1) : wait, () {
      resumeTimer = null;
      resumeTime = null;
      markAll();
    });
  }

  static String clockText(DateTime time) {
    final DateTime local = time.toLocal();
    final int hour = local.hour % 12 == 0 ? 12 : local.hour % 12;
    return '$hour:${local.minute.toString().padLeft(2, '0')} ${local.hour < 12 ? 'AM' : 'PM'}';
  }

  /// Stops processing, and any wait to resume. Finished stages stay cached.
  void cancelProcessing() {
    resumeTimer?.cancel();
    resumeTimer = null;
    resumeTime = null;
    final CancellationToken? token = runToken;
    if (token == null) return;
    setStatus('Cancelling…');
    token.cancel();
  }

  String summarise(CorrectionResult result) {
    final int count = result.questions.length;
    final StringBuffer summary = StringBuffer(
      'Marked $count question${count == 1 ? '' : 's'}: '
      '${formatMarks(result.totalMarks)} / '
      '${formatMarks(result.maximumTotalMarks)} '
      '(${formatPercentage(result.percentage)}).',
    );
    if (result.needsReviewCount > 0) {
      summary.write(' ${result.needsReviewCount} need your review.');
    }
    return summary.toString();
  }
}
