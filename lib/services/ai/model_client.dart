import 'dart:typed_data';

import 'package:exam_corrector/core/async/cancellation.dart';

/// One part of a multimodal request.
sealed class ContentPart {
  const ContentPart();
}

class TextPart extends ContentPart {
  const TextPart(this.text);

  final String text;
}

class ImagePart extends ContentPart {
  const ImagePart(this.bytes, {this.mimeType = 'image/png'});

  final Uint8List bytes;
  final String mimeType;
}

/// A request for structured output.
///
/// Every model call in the pipeline has this shape: an instruction, some text
/// and images, and a JSON Schema the answer must satisfy. The application
/// never parses free-form prose into marks or regions.
class ModelRequest {
  const ModelRequest({
    required this.purpose,
    required this.systemInstruction,
    required this.parts,
    required this.schema,
    this.maxTokens = 8000,
    this.effort = 'low',
    this.truncationHint =
        'The response was cut short because it exceeded the output limit.',
    this.refusalMessage = 'The AI declined this request.',
  });

  /// What the request is for, in the teacher's terms — "page analysis",
  /// "marking". Used in progress and error messages.
  final String purpose;

  final String systemInstruction;
  final List<ContentPart> parts;
  final Map<String, Object?> schema;
  final int maxTokens;

  /// Reasoning effort: `minimal`, `low`, `medium` or `high`. Perception tasks
  /// gain nothing from thinking; marking does.
  final String effort;
  final String truncationHint;
  final String refusalMessage;

  int get imageCount => parts.whereType<ImagePart>().length;
}

/// A decoded structured response, and which model produced it.
class ModelResponse {
  const ModelResponse({required this.payload, required this.model});

  final Object? payload;
  final String model;
}

/// The one boundary between the application and any model provider.
///
/// Page analysis, handwriting second opinions, visual analysis, question
/// extraction and marking all depend on this and nothing more specific.
/// Swapping provider means one new implementation; nothing above it changes.
abstract class ModelClient {
  /// Whether the client can make requests at all — a key is configured.
  bool get isAvailable;

  /// Sends [request] to the first model in [models] that can serve it,
  /// falling back down the list when one is out of quota or unavailable.
  ///
  /// Throws a `CorrectionException` carrying a teacher-facing message, or a
  /// `CancelledException`.
  Future<ModelResponse> requestJson(
    ModelRequest request, {
    required List<String> models,
    void Function(String message)? onProgress,
    CancellationToken? cancel,
  });
}
