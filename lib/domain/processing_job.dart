import 'package:exam_corrector/domain/json_read.dart';

/// Where a correction has got to.
///
/// Explicit, persisted, and ordered: each working stage caches its output, so
/// an interrupted correction resumes from the first stage that did not finish
/// rather than starting again.
enum ProcessingStage {
  uploaded('Ready to process'),
  extractingQuestions('Reading the question paper'),
  rendering('Rendering pages'),
  analyzingPages('Analysing pages'),
  detectingRegions('Detecting regions'),
  recognizingHandwriting('Recognising handwriting'),
  aligningQuestions('Matching answers to questions'),
  analyzingVisuals('Analysing diagrams, graphs, tables and equations'),
  reconstructingAnswers('Reconstructing answers'),
  marking('Marking'),
  reviewRequired('Marked — teacher review required'),
  completed('Completed'),
  failed('Failed'),
  cancelled('Cancelled');

  const ProcessingStage(this.label);

  final String label;

  /// The stages that do work, in the order they run.
  static const List<ProcessingStage> pipeline = <ProcessingStage>[
    extractingQuestions,
    rendering,
    analyzingPages,
    detectingRegions,
    recognizingHandwriting,
    aligningQuestions,
    analyzingVisuals,
    reconstructingAnswers,
    marking,
  ];

  bool get isTerminal => switch (this) {
        reviewRequired || completed || failed || cancelled => true,
        _ => false,
      };

  /// Share of the whole job each working stage accounts for. Rendering,
  /// recognition and marking dominate on a real script.
  double get weight => switch (this) {
        extractingQuestions => 0.05,
        rendering => 0.12,
        analyzingPages => 0.03,
        detectingRegions => 0.15,
        recognizingHandwriting => 0.25,
        aligningQuestions => 0.02,
        analyzingVisuals => 0.1,
        reconstructingAnswers => 0.02,
        marking => 0.26,
        _ => 0,
      };
}

/// What has been found so far — shown while processing runs.
class ProcessingCounts {
  const ProcessingCounts({
    this.pagesTotal = 0,
    this.pagesDone = 0,
    this.questions = 0,
    this.answerRegions = 0,
    this.handwritingRegions = 0,
    this.diagrams = 0,
    this.graphs = 0,
    this.tables = 0,
    this.equations = 0,
    this.crossedOut = 0,
    this.questionsMarked = 0,
  });

  final int pagesTotal;
  final int pagesDone;
  final int questions;
  final int answerRegions;
  final int handwritingRegions;
  final int diagrams;
  final int graphs;
  final int tables;
  final int equations;
  final int crossedOut;
  final int questionsMarked;

  ProcessingCounts copyWith({
    int? pagesTotal,
    int? pagesDone,
    int? questions,
    int? answerRegions,
    int? handwritingRegions,
    int? diagrams,
    int? graphs,
    int? tables,
    int? equations,
    int? crossedOut,
    int? questionsMarked,
  }) {
    return ProcessingCounts(
      pagesTotal: pagesTotal ?? this.pagesTotal,
      pagesDone: pagesDone ?? this.pagesDone,
      questions: questions ?? this.questions,
      answerRegions: answerRegions ?? this.answerRegions,
      handwritingRegions: handwritingRegions ?? this.handwritingRegions,
      diagrams: diagrams ?? this.diagrams,
      graphs: graphs ?? this.graphs,
      tables: tables ?? this.tables,
      equations: equations ?? this.equations,
      crossedOut: crossedOut ?? this.crossedOut,
      questionsMarked: questionsMarked ?? this.questionsMarked,
    );
  }

  JsonMap toJson() => <String, Object?>{
        'pagesTotal': pagesTotal,
        'pagesDone': pagesDone,
        'questions': questions,
        'answerRegions': answerRegions,
        'handwritingRegions': handwritingRegions,
        'diagrams': diagrams,
        'graphs': graphs,
        'tables': tables,
        'equations': equations,
        'crossedOut': crossedOut,
        'questionsMarked': questionsMarked,
      };

  static ProcessingCounts fromJson(JsonMap json) => ProcessingCounts(
        pagesTotal: readInt(json['pagesTotal']) ?? 0,
        pagesDone: readInt(json['pagesDone']) ?? 0,
        questions: readInt(json['questions']) ?? 0,
        answerRegions: readInt(json['answerRegions']) ?? 0,
        handwritingRegions: readInt(json['handwritingRegions']) ?? 0,
        diagrams: readInt(json['diagrams']) ?? 0,
        graphs: readInt(json['graphs']) ?? 0,
        tables: readInt(json['tables']) ?? 0,
        equations: readInt(json['equations']) ?? 0,
        crossedOut: readInt(json['crossedOut']) ?? 0,
        questionsMarked: readInt(json['questionsMarked']) ?? 0,
      );
}

/// One correction's progress through the pipeline.
class ProcessingJob {
  const ProcessingJob({
    required this.jobId,
    required this.stage,
    this.completedStages = const <ProcessingStage>{},
    this.reusedStages = const <ProcessingStage>{},
    this.stageFraction = 0,
    this.message = '',
    this.counts = const ProcessingCounts(),
    this.error,
    this.failedStage,
    this.warnings = const <String>[],
    this.updatedAt,
  });

  /// `<answer sheet hash>_<question paper hash>`: the same pair of files is
  /// the same job, which is what lets it resume.
  final String jobId;
  final ProcessingStage stage;
  final Set<ProcessingStage> completedStages;

  /// Stages whose output came from the cache rather than being recomputed.
  final Set<ProcessingStage> reusedStages;

  /// How far through the current stage, 0..1.
  final double stageFraction;
  final String message;
  final ProcessingCounts counts;
  final String? error;
  final ProcessingStage? failedStage;
  final List<String> warnings;
  final DateTime? updatedAt;

  /// Overall progress, 0..1, weighted by how long each stage typically takes.
  double get overallFraction {
    if (stage == ProcessingStage.completed ||
        stage == ProcessingStage.reviewRequired) {
      return 1;
    }
    double done = 0;
    for (final ProcessingStage s in ProcessingStage.pipeline) {
      if (completedStages.contains(s)) done += s.weight;
    }
    if (!completedStages.contains(stage)) {
      done += stage.weight * stageFraction.clamp(0.0, 1.0);
    }
    return done.clamp(0.0, 1.0);
  }

  bool get isRunning => !stage.isTerminal && stage != ProcessingStage.uploaded;

  ProcessingJob copyWith({
    ProcessingStage? stage,
    Set<ProcessingStage>? completedStages,
    Set<ProcessingStage>? reusedStages,
    double? stageFraction,
    String? message,
    ProcessingCounts? counts,
    String? Function()? error,
    ProcessingStage? Function()? failedStage,
    List<String>? warnings,
  }) {
    return ProcessingJob(
      jobId: jobId,
      stage: stage ?? this.stage,
      completedStages: completedStages ?? this.completedStages,
      reusedStages: reusedStages ?? this.reusedStages,
      stageFraction: stageFraction ?? this.stageFraction,
      message: message ?? this.message,
      counts: counts ?? this.counts,
      error: error == null ? this.error : error(),
      failedStage: failedStage == null ? this.failedStage : failedStage(),
      warnings: warnings ?? this.warnings,
      updatedAt: DateTime.now(),
    );
  }

  JsonMap toJson() => <String, Object?>{
        'jobId': jobId,
        'stage': stage.name,
        'completedStages': <String>[
          for (final ProcessingStage s in completedStages) s.name,
        ],
        'message': message,
        'counts': counts.toJson(),
        'error': ?error,
        'failedStage': ?failedStage?.name,
        'warnings': warnings,
        'updatedAt': (updatedAt ?? DateTime.now()).toUtc().toIso8601String(),
      };

  static ProcessingJob? fromJson(JsonMap json) {
    final String? id = readString(json['jobId']);
    if (id == null) return null;
    final String? failed = readString(json['failedStage']);
    return ProcessingJob(
      jobId: id,
      stage: readEnum(
        ProcessingStage.values,
        json['stage'],
        ProcessingStage.uploaded,
      ),
      completedStages: <ProcessingStage>{
        for (final Object? name in readList(json['completedStages']))
          readEnum(ProcessingStage.values, name, ProcessingStage.uploaded),
      }..remove(ProcessingStage.uploaded),
      message: readRawString(json['message']) ?? '',
      counts: ProcessingCounts.fromJson(
        readMap(json['counts']) ?? const <String, Object?>{},
      ),
      error: readString(json['error']),
      failedStage: failed == null
          ? null
          : readEnum(ProcessingStage.values, failed, ProcessingStage.failed),
      warnings: readStringList(json['warnings']),
      updatedAt: DateTime.tryParse(readString(json['updatedAt']) ?? ''),
    );
  }
}
