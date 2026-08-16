/// A student's exam paper after extraction: the file it came from, and the
/// text the AI will mark.
class ExamPaper {
  const ExamPaper({
    required this.filePath,
    required this.fileName,
    required this.text,
  });

  final String filePath;
  final String fileName;
  final String text;

  int get characterCount => text.length;
}
