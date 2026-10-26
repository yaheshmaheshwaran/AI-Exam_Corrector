/// Formats how long something took: `42s`, `4m 05s`, `1h 02m`.
///
/// Seconds stop mattering past an hour, so they are dropped there.
String formatElapsed(Duration value) {
  final int seconds = value.isNegative ? 0 : value.inSeconds;
  if (seconds < 60) return '${seconds}s';
  if (seconds < 3600) {
    return '${seconds ~/ 60}m ${(seconds % 60).toString().padLeft(2, '0')}s';
  }
  return '${seconds ~/ 3600}h ${(seconds % 3600 ~/ 60).toString().padLeft(2, '0')}m';
}
