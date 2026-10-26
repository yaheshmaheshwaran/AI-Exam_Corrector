import 'dart:io';
import 'dart:typed_data';

import 'package:exam_corrector/core/async/cancellation.dart';
import 'package:exam_corrector/ai/model_roles.dart';
import 'package:exam_corrector/core/errors/app_exception.dart';
import 'package:exam_corrector/domain/json_read.dart';
import 'package:exam_corrector/domain/question_label.dart';
import 'package:exam_corrector/models/question_result.dart';
import 'package:exam_corrector/marking/contracts.dart';
import 'package:exam_corrector/marking/marking_settings.dart';
import 'package:exam_corrector/marking/script/marker/marking_prompt.dart';
import 'package:exam_corrector/marking/script/checks/marking_validator.dart';
import 'package:exam_corrector/ai/model_request.dart';

/// [MarkingEngine] that marks with a model over text and images together.
///
/// Questions are marked in batches — a whole paper in one request would risk
/// the output limit and put every question's images in one context, while one
/// request per question would spend a day's quota on a single script.
class ModelMarkingEngine implements MarkingEngine {
  ModelMarkingEngine(this._client, this._settingsProvider);

  final ModelClient _client;
  final MarkingSettings Function() _settingsProvider;

  MarkingSettings get _config => _settingsProvider();

  /// Which model marked is recorded on every result and enforced by the
  /// judge, so it is not part of the key: reordering the backup models in
  /// Settings does not throw away a single mark.
  @override
  String get fingerprint => '${MarkingPrompt.version}:${_config.effort}';

  @override
  Future<List<QuestionResult>> mark(
    List<MarkingTask> tasks, {
    required String guidance,
    required bool typedAnswerSheet,
    String? judge,
    List<String>? models,
    StageProgress? onProgress,
    CancellationToken? cancel,
  }) async {
    // The first model to mark any of this script marks all of it.
    String? current = judge;
    final MarkingValidator validator =
        MarkingValidator(reviewThreshold: _config.reviewThreshold);
    final Map<String, QuestionResult> results = <String, QuestionResult>{};

    final List<MarkingTask> answered = <MarkingTask>[];
    for (final MarkingTask task in tasks) {
      if (task.answer.isEmpty) {
        results[task.question.questionId] = validator.unanswered(task);
      } else {
        answered.add(task);
      }
    }

    final List<List<MarkingTask>> batches = _batches(answered, _limits(judge, models));
    for (int index = 0; index < batches.length; index++) {
      cancel?.throwIfCancelled();
      final List<MarkingTask> batch = batches[index];
      onProgress?.call(
        'Marking ${_describe(batch)} (batch ${index + 1} of ${batches.length})…',
        index / batches.length,
      );

      Map<String, QuestionResult> marked = await _markSplitting(
        batch,
        validator,
        guidance: guidance,
        typedAnswerSheet: typedAnswerSheet,
        judge: current,
        models: models,
        onProgress: (String message) =>
            onProgress?.call(message, index / batches.length),
        cancel: cancel,
      );
      current ??= _judgeOf(marked);

      // A question the model skipped is asked about once more on its own
      // before it is handed to the teacher unmarked.
      final List<MarkingTask> missing = batch
          .where((MarkingTask t) => !marked.containsKey(t.question.questionId))
          .toList();
      if (missing.isNotEmpty) {
        marked = <String, QuestionResult>{
          ...marked,
          ...await _markBatch(
            missing,
            validator,
            guidance: guidance,
            typedAnswerSheet: typedAnswerSheet,
            judge: current,
            models: models,
            cancel: cancel,
          ),
        };
      }

      for (final MarkingTask task in batch) {
        results[task.question.questionId] = marked[task.question.questionId] ??
            validator.validate(
              task: task,
              raw: null,
              aliasToRegion: const <String, String>{},
              model: '',
            );
      }
    }

    onProgress?.call('Marking finished.', 1);
    return <QuestionResult>[
      for (final MarkingTask task in tasks) results[task.question.questionId]!,
    ];
  }

  /// [_markBatch], halving a batch whose answer was cut off at the output
  /// limit — a long script can outgrow one response, and two smaller
  /// requests succeed where the same one again would not.
  Future<Map<String, QuestionResult>> _markSplitting(
    List<MarkingTask> batch,
    MarkingValidator validator, {
    required String guidance,
    required bool typedAnswerSheet,
    String? judge,
    List<String>? models,
    void Function(String message)? onProgress,
    CancellationToken? cancel,
  }) async {
    try {
      return await _markBatch(
        batch,
        validator,
        guidance: guidance,
        typedAnswerSheet: typedAnswerSheet,
        judge: judge,
        models: models,
        onProgress: onProgress,
        cancel: cancel,
      );
    } on CorrectionException catch (error) {
      if (!error.truncated || batch.length < 2) rethrow;
      onProgress?.call('That batch was too long for one answer — marking it in two halves…');
      final int half = batch.length ~/ 2;
      final Map<String, QuestionResult> first = await _markSplitting(
        batch.sublist(0, half),
        validator,
        guidance: guidance,
        typedAnswerSheet: typedAnswerSheet,
        judge: judge,
        models: models,
        onProgress: onProgress,
        cancel: cancel,
      );
      return <String, QuestionResult>{
        ...first,
        ...await _markSplitting(
          batch.sublist(half),
          validator,
          guidance: guidance,
          typedAnswerSheet: typedAnswerSheet,
          // The first half chose the marker for the second.
          judge: judge ?? _judgeOf(first),
          models: models,
          onProgress: onProgress,
          cancel: cancel,
        ),
      };
    }
  }

  Future<Map<String, QuestionResult>> _markBatch(
    List<MarkingTask> batch,
    MarkingValidator validator, {
    required String guidance,
    required bool typedAnswerSheet,
    String? judge,
    List<String>? models,
    void Function(String message)? onProgress,
    CancellationToken? cancel,
  }) async {
    final Map<String, String> aliases = <String, String>{};
    final String text = MarkingPrompt.buildBatch(
      tasks: batch,
      aliases: aliases,
      guidance: guidance,
      typedAnswerSheet: typedAnswerSheet,
    );

    final List<ContentPart> parts = <ContentPart>[TextPart(text)];
    // One question with more images than a request holds sends its first
    // ones rather than failing; its text evidence is all there regardless.
    int budget = _limits(judge, models).imagesPerRequest;
    for (final MarkingTask task in batch) {
      for (final MarkingImage image in task.images) {
        if (budget <= 0) break;
        budget--;
        final Uint8List? bytes = await _read(image.path);
        if (bytes == null) continue;
        parts.add(
          TextPart('Image of [${aliases[image.regionId]}] — ${image.reason}, '
              'question ${task.question.questionId}:'),
        );
        parts.add(ImagePart(
          bytes,
          mimeType: image.path.toLowerCase().endsWith('.jpg') ? 'image/jpeg' : 'image/png',
        ));
      }
    }

    final ModelResponse response;
    try {
      response = await _client.requestJson(
        ModelRequest(
          purpose: 'marking',
          systemInstruction: MarkingPrompt.systemPrompt,
          parts: parts,
          schema: MarkingPrompt.schema,
          maxTokens: _config.maxTokens,
          effort: _config.effort,
          truncationHint: 'The marking was cut short because it exceeded the output limit.',
          refusalMessage: 'The AI declined to mark this paper. Please review the '
              'uploaded content.',
        ),
        // Once a model has marked part of the script, only it marks the rest.
        models: judge == null ? models ?? _config.chain(ModelRole.marker) : <String>[judge],
        onProgress: onProgress,
        cancel: cancel,
      );
    } on CorrectionException catch (error) {
      if (judge == null || !error.quotaExhausted) rethrow;
      throw CorrectionException(
        '$judge has marked this script so far and has no quota left. The rest '
        'of the script waits for it, so that one marker marks the whole '
        'script. ${error.message}',
        quotaExhausted: true,
        dailyQuota: error.dailyQuota,
        retryAfter: error.retryAfter,
      );
    }

    final Map<String, String> aliasToRegion = <String, String>{
      for (final MapEntry<String, String> entry in aliases.entries)
        entry.value.toUpperCase(): entry.key,
    };
    final List<JsonMap> items = readObjects(
      readMap(response.payload)?['questions'],
      (JsonMap m) => m,
    );
    final Map<String, JsonMap> byQuestion = matchToQuestions(items, batch);

    return <String, QuestionResult>{
      for (final MarkingTask task in batch)
        if (byQuestion[task.question.questionId] case final JsonMap raw)
          task.question.questionId: validator.validate(
            task: task,
            raw: raw,
            aliasToRegion: aliasToRegion,
            model: response.model,
          ),
    };
  }

  /// Pairs each returned item with its question.
  ///
  /// Models do not copy identifiers faithfully — asked for `Q8` they answer
  /// `8`, `Q 8` or `8.` — so an ID is resolved as a question label, the same
  /// way labels on the answer sheet are. A single question asked alone is
  /// paired with a single answer whatever it was called.
  static Map<String, JsonMap> matchToQuestions(
    List<JsonMap> items,
    List<MarkingTask> batch,
  ) {
    String? resolve(String written) {
      final String compact = written.toUpperCase().replaceAll(RegExp(r'\s'), '');
      for (final MarkingTask task in batch) {
        if (task.question.questionId.toUpperCase() == compact) {
          return task.question.questionId;
        }
      }
      final QuestionLabel? label = QuestionLabel.parse(written);
      if (label == null) return null;
      for (final MarkingTask task in batch) {
        if (task.question.label == label) return task.question.questionId;
      }
      return null;
    }

    final Map<String, JsonMap> matched = <String, JsonMap>{};
    for (final JsonMap item in items) {
      final String? id = resolve(readString(item['question_id']) ?? '');
      if (id != null) matched.putIfAbsent(id, () => item);
    }
    if (matched.isEmpty && batch.length == 1 && items.length == 1) {
      matched[batch.single.question.questionId] = items.single;
    }
    return matched;
  }

  /// Splits tasks so no request exceeds the question or image limits.
  static String? _judgeOf(Map<String, QuestionResult> marked) {
    for (final QuestionResult result in marked.values) {
      if (result.model.isNotEmpty) return result.model;
    }
    return null;
  }

  /// How much one request may carry for the model that will mark it.
  RequestLimits _limits(String? judge, List<String>? models) => _config.limitsForChain(
        judge != null ? <String>[judge] : models ?? _config.chain(ModelRole.marker),
      );

  List<List<MarkingTask>> _batches(List<MarkingTask> tasks, RequestLimits limits) {
    final int perRequest = limits.questionsPerRequest;
    final int imageBudget = limits.imagesPerRequest;
    final List<List<MarkingTask>> batches = <List<MarkingTask>>[];
    List<MarkingTask> current = <MarkingTask>[];
    int images = 0;

    for (final MarkingTask task in tasks) {
      final int needed = task.images.length;
      if (current.isNotEmpty &&
          (current.length >= perRequest || images + needed > imageBudget)) {
        batches.add(current);
        current = <MarkingTask>[];
        images = 0;
      }
      current.add(task);
      images += needed;
    }
    if (current.isNotEmpty) batches.add(current);
    return batches;
  }

  static String _describe(List<MarkingTask> batch) {
    if (batch.length == 1) return 'question ${batch.first.question.displayNumber}';
    return 'questions ${batch.first.question.displayNumber}–'
        '${batch.last.question.displayNumber}';
  }

  Future<Uint8List?> _read(String path) async {
    try {
      return await File(path).readAsBytes();
    } on IOException {
      return null;
    }
  }
}
