/// Tolerant readers for decoding cached artifacts and model responses.
///
/// Every domain model round-trips through JSON — that is what makes each
/// pipeline stage cacheable and resumable — and the same readers decode what
/// the sidecar and the AI send back. None of them throw: a missing or
/// malformed field becomes the caller's fallback, and the caller decides
/// whether that is acceptable.
library;

typedef JsonMap = Map<String, Object?>;

String? readString(Object? value) {
  if (value is! String) return null;
  final String trimmed = value.trim();
  return trimmed.isEmpty ? null : trimmed;
}

/// Unlike [readString], keeps surrounding whitespace and empty strings — for
/// transcriptions, where "" is a meaningful answer ("illegible").
String? readRawString(Object? value) => value is String ? value : null;

double? readDouble(Object? value) {
  if (value is! num || value is bool) return null;
  final double number = value.toDouble();
  return number.isFinite ? number : null;
}

int? readInt(Object? value) {
  if (value is int) return value;
  if (value is num && value is! bool && value.isFinite) return value.round();
  return null;
}

bool? readBool(Object? value) => value is bool ? value : null;

double readConfidence(Object? value, {double orElse = 0}) {
  final double? number = readDouble(value);
  if (number == null) return orElse;
  return number.clamp(0.0, 1.0);
}

JsonMap? readMap(Object? value) {
  if (value is Map<String, Object?>) return value;
  if (value is Map) {
    return <String, Object?>{
      for (final MapEntry<Object?, Object?> entry in value.entries)
        '${entry.key}': entry.value,
    };
  }
  return null;
}

List<Object?> readList(Object? value) =>
    value is List ? List<Object?>.of(value) : const <Object?>[];

List<String> readStringList(Object? value) => <String>[
      for (final Object? entry in readList(value))
        if (readString(entry) case final String text) text,
    ];

/// Decodes each map in a list with [decode], skipping entries it rejects.
List<T> readObjects<T>(Object? value, T? Function(JsonMap json) decode) {
  final List<T> decoded = <T>[];
  for (final Object? entry in readList(value)) {
    final JsonMap? map = readMap(entry);
    if (map == null) continue;
    final T? item = decode(map);
    if (item != null) decoded.add(item);
  }
  return decoded;
}

T readEnum<T extends Enum>(List<T> values, Object? name, T orElse) {
  if (name is! String) return orElse;
  for (final T value in values) {
    if (value.name == name) return value;
  }
  return orElse;
}
