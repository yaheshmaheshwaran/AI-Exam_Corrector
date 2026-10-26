import 'package:exam_corrector/ai/ai_settings.dart';
import 'package:exam_corrector/ai/model_roles.dart';

/// How much one request may carry, for one model.
class RequestLimits {
  const RequestLimits({
    required this.questionsPerRequest,
    required this.imagesPerRequest,
    required this.questionPaperPages,
    this.syllabusCharacters = 40000,
  });

  /// Questions marked, or keyed, in one request.
  final int questionsPerRequest;

  /// Images attached to one marking request.
  final int imagesPerRequest;

  /// Pages of a scanned question paper read at once.
  final int questionPaperPages;

  /// The longest syllabus text read at once; units come early, so little
  /// that matters is cut.
  final int syllabusCharacters;
}

/// What the marking pipeline needs to know beyond the AI layer's settings:
/// how hard to think, how much to send at once, and when a mark goes to the
/// teacher for review.
class MarkingSettings {
  const MarkingSettings({
    required this.ai,
    this.effort = 'high',
    this.maxTokens = 32000,
    this.reviewThreshold = 0.7,
    this.uncertainBelow = 0.9,
    this.limits,
  });

  final AiSettings ai;

  /// Reasoning effort for judgement — marking and answer keys.
  final String effort;

  /// The longest answer asked for when marking or writing a key.
  final int maxTokens;

  /// A mark the marker is less sure of than this goes to the teacher.
  final double reviewThreshold;

  /// Writing read with less confidence than this is flagged, and its ink is
  /// shown to the marker.
  final double uncertainBelow;

  /// Request limits for every model, in place of the ones by provider.
  final RequestLimits? limits;

  /// A copy with some request limits changed.
  MarkingSettings withLimits({int? questionsPerRequest, int? imagesPerRequest}) {
    final RequestLimits base = limits ?? limitsFor('');
    return MarkingSettings(
      ai: ai,
      effort: effort,
      maxTokens: maxTokens,
      reviewThreshold: reviewThreshold,
      uncertainBelow: uncertainBelow,
      limits: RequestLimits(
        questionsPerRequest: questionsPerRequest ?? base.questionsPerRequest,
        imagesPerRequest: imagesPerRequest ?? base.imagesPerRequest,
        questionPaperPages: base.questionPaperPages,
        syllabusCharacters: base.syllabusCharacters,
      ),
    );
  }

  List<String> chain(ModelRole role) => ai.roles.chain(role);

  /// A hosted model takes a whole script's questions at once; one on our own
  /// hardware has a small context and is given less.
  RequestLimits limitsFor(String model) => limits ?? ((ai.providers.of(model)?.selfHosted ?? false)
      ? const RequestLimits(questionsPerRequest: 8, imagesPerRequest: 8, questionPaperPages: 8, syllabusCharacters: 20000)
      : const RequestLimits(questionsPerRequest: 30, imagesPerRequest: 16, questionPaperPages: 20));

  /// Limits for a request that may go to any of [models]: the first, which
  /// is the one asked unless it fails.
  RequestLimits limitsForChain(List<String> models) =>
      models.isEmpty ? limitsFor('') : limitsFor(models.first);
}
