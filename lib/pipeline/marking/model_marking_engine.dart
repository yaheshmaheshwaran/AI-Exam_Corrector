import 'dart:io';
import 'dart:typed_data';

import 'package:exam_corrector/core/async/cancellation.dart';
import 'package:exam_corrector/core/config/app_config.dart';
import 'package:exam_corrector/domain/json_read.dart';
import 'package:exam_corrector/domain/question_label.dart';
import 'package:exam_corrector/models/question_result.dart';
import 'package:exam_corrector/pipeline/engines.dart';
import 'package:exam_corrector/pipeline/marking/marking_prompt.dart';
import 'package:exam_corrector/pipeline/marking/marking_validator.dart';
import 'package:exam_corrector/services/ai/model_client.dart';

/// [MarkingEngine] that marks with a model over text and images together.
///
/// Questions are marked in batches — a whole paper in one request would risk
/// the output limit and put every question's images in one context, while one
/// request per question would spend a day's quota on a single script.
class ModelMarkingEngine implements MarkingEngine {
  ModelMarkingEngine(this._client, this._configProvider);

  final ModelClient _client;
  final AppConfig Function() _configProvider;

  AppConfig get _config => _configProvider();

  @override
  String get fingerprint =>
      '${MarkingPrompt.version}:${_config.modelChain.join(',')}:${_config.effort}';

  @override
  Future<List<QuestionResult>> mark(
    List<MarkingTask> tasks, {
    required String guidance,
    required bool typedAnswerSheet,
    StageProgress? onProgress,
    CancellationToken? cancel,
  }) async {
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

    final List<List<MarkingTask>> batches = _batches(answered);
    for (int index = 0; index < batches.length; index++) {
      cancel?.throwIfCancelled();
      final List<MarkingTask> batch = batches[index];
      onProgress?.call(
        'Marking ${_describe(batch)} (batch ${index + 1} of ${batches.length})…',
        index / batches.length,
      );

      Map<String, QuestionResult> marked = await _markBatch(
        batch,
        validator,
        guidance: guidance,
        typedAnswerSheet: typedAnswerSheet,
        onProgress: (String message) =>
            onProgress?.call(message, index / batches.length),
        cancel: cancel,
      );

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

  Future<Map<String, QuestionResult>> _markBatch(
    List<MarkingTask> batch,
    MarkingValidator validator, {
    required String guidance,
    required bool typedAnswerSheet,
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
    for (final MarkingTask task in batch) {
      for (final MarkingImage image in task.images) {
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

    final ModelResponse response = await _client.requestJson(
      ModelRequest(
        purpose: 'marking',
        systemInstruction: MarkingPrompt.systemPrompt,
        parts: parts,
        schema: MarkingPrompt.schema,
        maxTokens: _config.maxTokens,
        effort: _config.effort,
        truncationHint: 'The marking was cut short because it exceeded the '
            'output limit. Lower EXAM_CORRECTOR_QUESTIONS_PER_REQUEST, or raise '
            'EXAM_CORRECTOR_MAX_TOKENS.',
        refusalMessage: 'The AI declined to mark this paper. Please review the '
            'uploaded content.',
      ),
      models: _config.modelChain,
      onProgress: onProgress,
      cancel: cancel,
    );

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
  List<List<MarkingTask>> _batches(List<MarkingTask> tasks) {
    final int perRequest = _config.questionsPerMarkingRequest;
    final int imageBudget = _config.maxImagesPerRequest;
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
