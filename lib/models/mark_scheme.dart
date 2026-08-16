/// The marking criteria supplied by the teacher.
///
/// The mark scheme is the sole authority for awarding marks; this type exists
/// so that authority travels through the app as a named thing rather than a
/// bare string.
class MarkScheme {
  const MarkScheme(this.text);

  final String text;

  String get trimmed => text.trim();

  bool get isEmpty => trimmed.isEmpty;
}
