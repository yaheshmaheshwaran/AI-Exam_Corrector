// Marks one student's whole answer script with the new pipeline and reports
// what each stage made of it, and how long each took.
//
//   dart run tool/mark_one_script.dart [options]
//
//   --script <pdf>     the student's script (default: the DocScanner script in
//                      user_inputs/ans)
//   --paper <pdf>      the question paper (default: the IoT paper in
//                      user_inputs/qus)
//   --reader <models>  reader models, comma-separated, first choice first,
//                      e.g. gemini/gemini-3.1-flash-lite
//   --marker <models>  marking models, e.g. gemini/gemini-3.5-flash or
//                      nvidia/moonshotai/kimi-k3
//   --prep <models>    question paper and answer key models
//   --read-only        stop after reading: no answer key, no marking
//   --tag <name>       mark again under this name, keeping every earlier stage —
//                      to see whether a model gives the same marks twice
//   --out <dir>        where results go (default build/mark-one-script/<marker>)
//   --fresh            ignore saved results and do everything again
//                      (spends requests)
//
// Writes, in the output folder: transcript.md (every page as read), marks.json
// (each question's marks and the total), summary.json (stage times, requests
// per model, warnings), and a report of any line that looks like an
// examiner's mark. Compare the marks with an examiner's afterwards with
// tool/compare_examiner.dart — this tool never reads them.
//
// Results are saved in build/mark-one-script/cache, so running again spends
// nothing for the stages whose inputs did not change.
import 'dart:convert';
import 'dart:io';

import 'package:exam_corrector/ai/ai_settings.dart';
import 'package:exam_corrector/ai/llm_client.dart';
import 'package:exam_corrector/ai/model_roles.dart';
import 'package:exam_corrector/ai/usage.dart';
import 'package:exam_corrector/core/errors/app_exception.dart';
import 'package:exam_corrector/domain/evidence.dart';
import 'package:exam_corrector/domain/exam_assessment.dart';
import 'package:exam_corrector/domain/exam_document.dart';
import 'package:exam_corrector/domain/page_region.dart';
import 'package:exam_corrector/domain/processing_job.dart';
import 'package:exam_corrector/domain/student_answer.dart';
import 'package:exam_corrector/marking/contracts.dart';
import 'package:exam_corrector/marking/document_reader.dart';
import 'package:exam_corrector/marking/hooks.dart';
import 'package:exam_corrector/marking/marking_pipeline.dart';
import 'package:exam_corrector/marking/marking_settings.dart';
import 'package:exam_corrector/marking/script/examiner_marks.dart';
import 'package:exam_corrector/marking/stage_store.dart';
import 'package:exam_corrector/models/correction_result.dart';
import 'package:exam_corrector/models/question_result.dart';

Future<void> main(List<String> args) async {
  final Map<String, String> options = _options(args);
  final String script = options['script'] ?? 'user_inputs/ans/DocScanner 02-Sep-2026 11-22 AM copy.pdf';
  final String paperPath = options['paper'] ?? 'user_inputs/qus/IoT Question Paper-3.pdf';
  for (final String path in <String>[script, paperPath]) {
    if (!File(path).existsSync()) {
      stderr.writeln('No such file: $path');
      exitCode = 66;
      return;
    }
  }

  final AiSettings loaded = await AiSettings.load();
  for (final String warning in loaded.warnings) {
    stdout.writeln('Setting ignored: $warning');
  }
  ModelRoles roles = loaded.roles;
  for (final (String option, ModelRole role) in <(String, ModelRole)>[
    ('reader', ModelRole.reader),
    ('marker', ModelRole.marker),
    ('prep', ModelRole.prep),
  ]) {
    if (options[option] case final String models when models.isNotEmpty) {
      roles = roles.withChain(role, ModelRoles.parseList(models));
    }
  }
  final AiSettings ai = loaded.copyWith(roles: roles);
  final MarkingSettings settings = MarkingSettings(ai: ai);
  final UsageMonitor usage = await UsageMonitor.ofApp(
    dailyAllowance: (String model) => ai.providers.of(model)?.dailyAllowance ?? false,
  );
  final MarkingPipeline pipeline = MarkingPipeline(
    settings: () => settings,
    store: StageStore(Directory('build/mark-one-script/cache'), enabled: !options.containsKey('fresh')),
    client: LlmClient(() => ai, usage: usage),
    hooks: <MarkingHook>[if (options['tag'] case final String tag when tag.isNotEmpty) _RunTag(tag)],
  );

  final Directory out =
      Directory(options['out'] ?? 'build/mark-one-script/${_slug(roles.marker.first)}')..createSync(recursive: true);
  stdout.writeln('Script:  $script');
  stdout.writeln('Paper:   $paperPath');
  stdout.writeln('Prep:    ${roles.prep.join(' → ')}');
  stdout.writeln('Reader:  ${roles.reader.join(' → ')}');
  stdout.writeln('Marker:  ${roles.marker.join(' → ')}\n');

  const DocumentReader documents = DocumentReader();
  final SelectedDocument answers = await documents.inspect(script, DocumentRole.answerSheet);
  final SelectedDocument paper = await documents.inspect(paperPath, DocumentRole.questionPaper);
  final Map<String, int> requestsBefore = _requests(usage);
  final Stopwatch total = Stopwatch()..start();

  ProcessingStage? shown;
  final ExamAssessment assessment;
  try {
    assessment = await pipeline.run(
      answerSheet: answers,
      questionPaper: paper,
      prepareOnly: options.containsKey('read-only'),
      onUpdate: (ProcessingJob job) {
        if (job.stage != shown && !job.stage.isTerminal) {
          if (shown != null) stdout.writeln();
          shown = job.stage;
        }
        stdout.write('\r  ${job.stage.label}: ${job.message}'.padRight(110).substring(0, 110));
      },
    );
  } on AppException catch (error) {
    stdout.writeln('\n\nStopped: ${error.message}');
    exitCode = 1;
    return;
  }
  stdout.writeln('\n');

  // Stage times.
  final Map<String, double> seconds = <String, double>{
    for (final MapEntry<ProcessingStage, Duration> e in assessment.job.durations.entries)
      e.key.name: e.value.inMilliseconds / 1000,
  };
  for (final ProcessingStage stage in ProcessingStage.pipeline) {
    final double? s = seconds[stage.name];
    if (s == null) continue;
    final bool reused = assessment.job.reusedStages.contains(stage);
    stdout.writeln('  ${stage.label.padRight(32)} ${s.toStringAsFixed(1).padLeft(6)} s${reused ? '  (saved result)' : ''}');
  }
  final Map<String, int> requests = _spent(requestsBefore, _requests(usage));

  // Transcript and the examiner-mark check.
  final List<String> leaks = <String>[];
  final StringBuffer transcript = StringBuffer('# ${answers.fileName}\n');
  for (final ExamPage page in assessment.answerSheet.pages) {
    transcript.writeln('\n## Page ${page.pageNumber}${page.isBlank ? ' (blank)' : ''}\n');
    for (final PageRegion region in page.regions) {
      final HandwritingEvidence? writing = assessment.evidence.handwriting[region.regionId];
      final VisualEvidence? visual = assessment.evidence.visuals[region.regionId];
      final String label = region.detectedLabel == null ? '' : ' «${region.detectedLabel}»';
      final String question = assessment.alignment.questionsByRegion[region.regionId]?.join(', ') ?? '—';
      transcript.writeln('**${region.type.displayName}**$label → $question');
      if (writing != null) {
        transcript.writeln('```\n${writing.effectiveText}\n```');
        for (final String line in ExaminerMarks.suspicious(writing.rawText)) {
          leaks.add('page ${page.pageNumber}, ${region.regionId}: "$line"');
        }
      }
      if (visual != null) transcript.writeln('_${visual.kind.displayName}: ${visual.description}_');
    }
  }
  await File('${out.path}/transcript.md').writeAsString(transcript.toString());

  // Marks.
  final CorrectionResult? result = assessment.result;
  final List<Map<String, Object?>> marks = <Map<String, Object?>>[];
  if (result != null) {
    stdout.writeln('\n  Question   Marks      Model / notes');
    for (final QuestionResult q in result.questions) {
      final StudentAnswer? answer = assessment.answers[q.questionId];
      marks.add(<String, Object?>{
        'question': q.questionNumber,
        'questionId': q.questionId,
        'awarded': q.awardedMarks,
        'maximum': q.maximumMarks,
        'counted': q.counted,
        'needsReview': q.needsReview,
        'model': q.model,
        'answerPages': answer?.pages ?? const <int>[],
      });
      stdout.writeln('  ${q.questionNumber.padRight(10)} ${'${_n(q.awardedMarks)}/${_n(q.maximumMarks)}'.padRight(10)} '
          '${q.model}${q.counted ? '' : ' (not counted: other option)'}${q.needsReview ? ' · review' : ''}');
    }
    stdout.writeln('\n  Total: ${_n(result.totalMarks)} / ${_n(result.maximumTotalMarks)}');
  } else if (!options.containsKey('read-only')) {
    stdout.writeln('\n  Not marked. ${assessment.warnings.isEmpty ? '' : assessment.warnings.last}');
  }
  const JsonEncoder pretty = JsonEncoder.withIndent(' ');
  await File('${out.path}/marks.json').writeAsString(pretty.convert(<String, Object?>{
    'script': script,
    'paper': paperPath,
    'marker': roles.marker,
    'total': result?.totalMarks,
    'maximum': result?.maximumTotalMarks,
    'questions': marks,
  }));
  await File('${out.path}/summary.json').writeAsString(pretty.convert(<String, Object?>{
    'roles': <String, Object?>{'prep': roles.prep, 'reader': roles.reader, 'marker': roles.marker},
    'seconds': seconds,
    'totalSeconds': total.elapsedMilliseconds / 1000,
    'requests': requests,
    'possibleExaminerMarks': leaks,
    'warnings': assessment.warnings,
  }));
  await usage.saved;

  stdout.writeln('\nRequests: ${requests.isEmpty ? 'none' : requests.entries.map((MapEntry<String, int> e) => '${e.key} × ${e.value}').join(', ')}');
  for (final String warning in assessment.warnings) {
    stdout.writeln('Warning: $warning');
  }
  stdout.writeln(leaks.isEmpty
      ? 'Examiner-mark check: no line looks like a score or tick.'
      : 'Examiner-mark check: ${leaks.length} line(s) look like a score or tick:\n  ${leaks.join('\n  ')}');
  stdout.writeln('Total time: ${(total.elapsedMilliseconds / 1000).toStringAsFixed(1)} s → ${out.path}');
}

/// Adds nothing to what the marker sees; only gives this run's marks a cache
/// key of their own, so the script is marked afresh.
class _RunTag implements MarkingHook {
  const _RunTag(this.tag);

  final String tag;

  @override
  String get fingerprint => 'run:$tag';

  @override
  Future<List<MarkingTask>> beforeMarking(List<MarkingTask> tasks, ExamAssessment assessment) async => tasks;
}

String _n(double? value) {
  if (value == null) return '?';
  return value == value.roundToDouble() ? value.toInt().toString() : value.toStringAsFixed(2);
}

Map<String, int> _requests(UsageMonitor usage) =>
    <String, int>{for (final MapEntry<String, DayUsage> e in usage.today.entries) e.key: e.value.requests};

Map<String, int> _spent(Map<String, int> before, Map<String, int> after) => <String, int>{
      for (final MapEntry<String, int> e in after.entries)
        if (e.value - (before[e.key] ?? 0) > 0) e.key: e.value - (before[e.key] ?? 0),
    };

Map<String, String> _options(List<String> args) {
  final Map<String, String> options = <String, String>{};
  for (int i = 0; i < args.length; i++) {
    if (!args[i].startsWith('--')) continue;
    final String name = args[i].substring(2);
    final bool hasValue = i + 1 < args.length && !args[i + 1].startsWith('--');
    options[name] = hasValue ? args[++i] : '';
  }
  return options;
}

String _slug(String model) => model.replaceAll(RegExp('[^A-Za-z0-9.-]+'), '_');
