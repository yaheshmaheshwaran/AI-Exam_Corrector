/// The three jobs a model does in Marklume.
enum ModelRole {
  /// Once per exam: reading the question paper, writing the answer key,
  /// matching the teacher's key, structuring a syllabus.
  prep('exam preparation', 'EXAM_CORRECTOR_PREP_MODELS'),

  /// Every student: reading the pages — handwriting, diagrams, equations.
  reader('page reading', 'EXAM_CORRECTOR_READER_MODELS'),

  /// Every student: marking the answers against the key. One model marks a
  /// whole script.
  marker('marking', 'EXAM_CORRECTOR_MARKER_MODELS');

  const ModelRole(this.label, this.settingName);

  final String label;

  /// The setting that lists its models, comma-separated, first choice first.
  final String settingName;
}

/// Which models do each job, first choice first; the rest are backups, used
/// in order when one is out of allowance or not answering.
class ModelRoles {
  const ModelRoles({required this.prep, required this.reader, required this.marker});

  final List<String> prep;
  final List<String> reader;
  final List<String> marker;

  /// Chosen on 2026-10-06: exam prep from published benchmarks, the reader
  /// and the marker by tests on a real script (see
  /// docs/decisions/2026-10-06-one-pipeline.md).
  static const ModelRoles defaults = ModelRoles(
    prep: <String>['nvidia/moonshotai/kimi-k3', 'nvidia/z-ai/glm-5.3', 'gemini/gemini-3.5-flash'],
    reader: <String>['gemini/gemini-3.1-flash-lite', 'server/Qwen/Qwen3-VL-8B-Instruct'],
    marker: <String>['gemini/gemini-3.5-flash', 'nvidia/moonshotai/kimi-k3'],
  );

  List<String> chain(ModelRole role) => switch (role) {
        ModelRole.prep => prep,
        ModelRole.reader => reader,
        ModelRole.marker => marker,
      };

  ModelRoles withChain(ModelRole role, List<String> models) => ModelRoles(
        prep: role == ModelRole.prep ? models : prep,
        reader: role == ModelRole.reader ? models : reader,
        marker: role == ModelRole.marker ? models : marker,
      );

  /// Reads each role's list from settings; a role not set keeps its default.
  static ModelRoles fromSettings(String? Function(String key) read) {
    ModelRoles roles = defaults;
    for (final ModelRole role in ModelRole.values) {
      final List<String> models = parseList(read(role.settingName) ?? '');
      if (models.isNotEmpty) roles = roles.withChain(role, models);
    }
    return roles;
  }

  static List<String> parseList(String value) =>
      value.split(',').map((String model) => model.trim()).where((String model) => model.isNotEmpty).toList();
}
