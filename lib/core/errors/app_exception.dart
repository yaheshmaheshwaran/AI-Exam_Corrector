/// Failures that carry a message written for a teacher, not for a developer.
///
/// Every layer that can fail raises one of these, so the UI never has to
/// interpret a raw platform error.
sealed class AppException implements Exception {
  const AppException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Required configuration is missing or invalid.
class ConfigException extends AppException {
  const ConfigException(super.message);
}

/// A PDF could not be read or contains no usable text.
class PdfExtractionException extends AppException {
  const PdfExtractionException(super.message);
}

/// Something the results database cannot do: a request already open, a
/// mark out of range.
class ResultsException extends AppException {
  const ResultsException(super.message);
}

/// Signing in, signing up or managing a college's members failed: a wrong
/// password, a college ID that does not exist, or the college server out of
/// reach.
class AccountException extends AppException {
  const AccountException(super.message, {this.offline = false});

  /// The college server could not be reached, rather than refusing.
  final bool offline;
}

/// A syllabus file could not be read or understood.
class SyllabusException extends AppException {
  const SyllabusException(super.message);
}

/// The teacher's answer key file could not be read.
class AnswerKeyException extends AppException {
  const AnswerKeyException(super.message);
}

/// Correction failed for a reason the teacher should see.
class CorrectionException extends AppException {
  const CorrectionException(
    super.message, {
    this.transient = false,
    this.retryAfter,
    this.quotaExhausted = false,
    this.dailyQuota = false,
    this.modelUnavailable = false,
    this.truncated = false,
    this.quotaLimit,
    this.unreachable = false,
  });

  /// True when the server could not be reached at all — not running, its
  /// tunnel closed, no network. Another model may serve the request, and the
  /// server is skipped until it is seen to answer again.
  final bool unreachable;

  /// The allowance the provider said was reached ("limit: 20"), when it did:
  /// shown to the teacher so a spent free tier is not a mystery.
  final int? quotaLimit;

  /// True when the answer was cut off at the output limit. Asking for less
  /// at once — fewer questions, fewer pages — succeeds where retrying would
  /// not.
  final bool truncated;

  /// True when this model cannot be used at all with this key — retired,
  /// renamed, or not offered on the key's plan. Retrying is pointless, but
  /// another model may well serve the request.
  final bool modelUnavailable;

  /// True when what ran out is the model's allowance for the day — which
  /// comes back only when the provider resets it, not in a minute.
  final bool dailyQuota;

  /// True when this model has no allowance left. Waiting will not help, but
  /// another model has its own quota, so marking moves on to the next one.
  final bool quotaExhausted;

  /// True when the same request could well succeed shortly — a rate limit, a
  /// busy model, or a dropped connection. The service retries these before
  /// troubling the teacher with them.
  final bool transient;

  /// How long the API asked us to wait, when it said. Honouring this is the
  /// difference between a retry that works and one that is refused again.
  final Duration? retryAfter;
}

/// The AI response cannot be trusted to display as marks.
class ResultValidationException extends AppException {
  const ResultValidationException(super.message);
}

/// The teacher cancelled processing. Not a failure: everything finished so far
/// is cached, and starting again picks up where this stopped.
class CancelledException extends AppException {
  const CancelledException() : super('Processing was cancelled.');
}

/// A stage of the understanding pipeline failed in a way that stops it.
///
/// Carries the stage so the teacher is told where it stopped — "page 7 could
/// not be rendered" is actionable where "processing failed" is not.
class PipelineException extends AppException {
  const PipelineException(super.message, {this.stage, this.page});

  final String? stage;
  final int? page;
}
