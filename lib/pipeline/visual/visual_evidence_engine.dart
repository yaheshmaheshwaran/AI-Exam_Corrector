import 'dart:async';

import 'package:exam_corrector/core/async/cancellation.dart';
import 'package:exam_corrector/core/errors/app_exception.dart';
import 'package:exam_corrector/domain/evidence.dart';
import 'package:exam_corrector/domain/page_region.dart';
import 'package:exam_corrector/pipeline/engines.dart';

/// Routes each visual region to the analyser for its kind.
///
/// Failure is contained per kind and per region: a diagram whose analysis
/// failed keeps its image and gets a record saying why, so the marking engine
/// can still look at it, and the teacher can see that it was not analysed.
class VisualEvidenceEngine {
  const VisualEvidenceEngine({
    this.diagrams,
    this.graphs,
    this.tables,
    this.equations,
  });

  final DiagramAnalyzer? diagrams;
  final GraphAnalyzer? graphs;
  final TableAnalyzer? tables;
  final EquationRecognizer? equations;

  /// Requests in flight at once. Side by side saves minutes on a page of
  /// visuals, but a free tier counts requests per minute too, and a burst of
  /// four trips it.
  static const int maxConcurrent = 2;

  bool get hasAnyAnalyzer =>
      diagrams != null || graphs != null || tables != null || equations != null;

  Future<({Map<String, VisualEvidence> evidence, List<String> warnings})> analyze(
    List<VisualTask> tasks, {
    StageProgress? onProgress,
    CancellationToken? cancel,
  }) async {
    final Map<String, VisualEvidence> evidence = <String, VisualEvidence>{};
    final List<String> warnings = <String>[];

    List<VisualTask> of(Set<RegionType> kinds) =>
        tasks.where((VisualTask t) => kinds.contains(t.region.type)).toList();

    final List<({
      String label,
      List<VisualTask> tasks,
      Future<Map<String, VisualEvidence>> Function(List<VisualTask>)? run,
    })> groups = <({
      String label,
      List<VisualTask> tasks,
      Future<Map<String, VisualEvidence>> Function(List<VisualTask>)? run,
    })>[
      (
        label: 'diagram',
        tasks: of(<RegionType>{RegionType.diagram, RegionType.unknown}),
        run: diagrams == null
            ? null
            : (List<VisualTask> t) =>
                diagrams!.analyzeDiagrams(t, cancel: cancel),
      ),
      (
        label: 'graph',
        tasks: of(<RegionType>{RegionType.graph}),
        run: graphs == null
            ? null
            : (List<VisualTask> t) => graphs!.analyzeGraphs(t, cancel: cancel),
      ),
      (
        label: 'table',
        tasks: of(<RegionType>{RegionType.table}),
        run: tables == null
            ? null
            : (List<VisualTask> t) => tables!.analyzeTables(t, cancel: cancel),
      ),
      (
        label: 'equation',
        tasks: of(<RegionType>{RegionType.equation}),
        run: equations == null
            ? null
            : (List<VisualTask> t) =>
                equations!.recognizeEquations(t, cancel: cancel),
      ),
    ];

    // The kinds are independent requests, so they run side by side: a page
    // with a diagram, a table and a graph waits for the slowest analysis, not
    // for all of them in turn.
    final List<({
      String label,
      List<VisualTask> tasks,
      Future<Map<String, VisualEvidence>> Function(List<VisualTask>)? run,
    })> active = groups.where((g) => g.tasks.isNotEmpty).toList();
    cancel?.throwIfCancelled();
    onProgress?.call(
      'Analysing ${active.map((g) => '${g.tasks.length} ${g.label}(s)').join(', ')}…',
      0,
    );

    int finished = 0;
    final _Slots slots = _Slots(maxConcurrent);
    final List<({Map<String, VisualEvidence> result, String? failure})> outcomes =
        await Future.wait(<Future<({Map<String, VisualEvidence> result, String? failure})>>[
      for (final group in active)
        slots.run(() async {
          Map<String, VisualEvidence> result = const <String, VisualEvidence>{};
          String? failure;
          if (group.run == null) {
            failure = 'no analyser is available';
          } else {
            try {
              result = await group.run!(group.tasks);
            } on CorrectionException catch (error) {
              failure = error.message;
            }
          }
          finished++;
          onProgress?.call('Analysed ${group.label}s ($finished of ${active.length})…',
              finished / active.length);
          return (result: result, failure: failure);
        }),
    ]);
    cancel?.throwIfCancelled();

    for (int g = 0; g < active.length; g++) {
      final group = active[g];
      final Map<String, VisualEvidence> result = outcomes[g].result;
      final String? failure = outcomes[g].failure;
      for (final VisualTask task in group.tasks) {
        final String id = task.region.regionId;
        evidence[id] = result[id] ??
            VisualEvidence.unanalysed(
              regionId: id,
              kind: task.region.type,
              status: group.run == null
                  ? AnalysisStatus.skipped
                  : AnalysisStatus.failed,
              error: failure ?? 'The analyser returned nothing for this image.',
            );
      }
      if (failure != null) {
        warnings.add(
          '${group.tasks.length} ${group.label}(s) were not analysed '
          '($failure). Their images are kept and shown to the marker.',
        );
      }
    }
    return (evidence: evidence, warnings: warnings);
  }
}

/// Runs at most [limit] tasks at a time, in the order they were given.
class _Slots {
  _Slots(this.limit);

  final int limit;
  int _running = 0;
  final List<Completer<void>> _waiting = <Completer<void>>[];

  Future<T> run<T>(Future<T> Function() task) async {
    if (_running >= limit) {
      final Completer<void> turn = Completer<void>();
      _waiting.add(turn);
      await turn.future;
    }
    _running++;
    try {
      return await task();
    } finally {
      _running--;
      if (_waiting.isNotEmpty) _waiting.removeAt(0).complete();
    }
  }
}
