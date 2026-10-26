/// Where a model runs: one OpenAI-compatible server.
///
/// Every provider Marklume uses speaks the same chat-completions API, so one
/// client serves them all; what differs is the address, the key, and how the
/// server behaves — whether it holds an answer to a JSON Schema, how long it
/// may stay silent, whether its allowance is a day's.
class ModelProvider {
  const ModelProvider({
    required this.id,
    required this.label,
    required this.baseUrl,
    this.apiKey,
    this.keyName,
    this.addressName,
    this.selfHosted = false,
    this.needsKey = true,
    this.jsonSchema = true,
    this.sendsEffort = false,
    this.dailyAllowance = false,
    this.maxAnswerTokens = 8192,
    this.headerTimeout = const Duration(seconds: 90),
    this.idleTimeout = const Duration(seconds: 120),
    this.totalTimeout = const Duration(minutes: 15),
  });

  /// The prefix that names it in a model name: `gemini` in
  /// `gemini/gemini-3.5-flash`.
  final String id;

  /// What the teacher calls it.
  final String label;

  /// Everything before `/chat/completions`.
  final String? baseUrl;
  final String? apiKey;

  /// The setting that holds its key, and its address, for messages.
  final String? keyName;
  final String? addressName;

  /// On our own hardware (Kaggle, this computer): a 429 means busy, never
  /// out of allowance, and a server that stops answering is skipped a while.
  final bool selfHosted;
  final bool needsKey;

  /// Whether it accepts `response_format: json_schema`; otherwise it is asked
  /// for a JSON object, with the schema written into the instruction.
  final bool jsonSchema;

  /// Whether `reasoning_effort` is sent: only where the server is known to
  /// accept it.
  final bool sendsEffort;

  /// Whether a spent allowance lasts until the provider's day resets, rather
  /// than a few minutes.
  final bool dailyAllowance;

  /// The longest answer it is asked for.
  final int maxAnswerTokens;

  /// How long to wait for it to start answering.
  final Duration headerTimeout;

  /// How long it may stay silent mid-answer.
  final Duration idleTimeout;

  /// How long one answer may take in all. A server that hangs — streams a
  /// little, then nothing, or keeps a connection open without answering — is
  /// left for the next model instead of waited on.
  final Duration totalTimeout;

  bool get isConfigured => (baseUrl?.isNotEmpty ?? false) && (!needsKey || (apiKey?.isNotEmpty ?? false));

  /// The model's name on the server: [model] without this provider's prefix.
  String modelId(String model) => model.startsWith('$id/') ? model.substring(id.length + 1) : model;
}

/// A model name split into its provider and the server's own name for it.
///
/// Only the first slash separates them: `nvidia/moonshotai/kimi-k3` is
/// `moonshotai/kimi-k3` on NVIDIA.
({String provider, String model})? parseModelName(String name) {
  final String trimmed = name.trim();
  final int slash = trimmed.indexOf('/');
  if (slash <= 0 || slash == trimmed.length - 1) return null;
  return (provider: trimmed.substring(0, slash), model: trimmed.substring(slash + 1));
}

/// The providers Marklume can use, configured from settings.
class Providers {
  const Providers(this._byId);

  final Map<String, ModelProvider> _byId;

  static const String gemini = 'gemini';
  static const String nvidia = 'nvidia';
  static const String server = 'server';
  static const String ollama = 'ollama';

  static const String geminiKeyName = 'GEMINI_API_KEY';
  static const String googleKeyName = 'GOOGLE_API_KEY';
  static const String nvidiaKeyName = 'NVIDIA_API_KEY';
  static const String serverAddressName = 'EXAM_CORRECTOR_MODEL_SERVER_URL';
  static const String serverKeyName = 'EXAM_CORRECTOR_MODEL_SERVER_KEY';
  static const String ollamaAddressName = 'EXAM_CORRECTOR_OLLAMA_URL';
  static const String geminiAddressName = 'EXAM_CORRECTOR_GEMINI_URL';
  static const String nvidiaAddressName = 'EXAM_CORRECTOR_NVIDIA_URL';

  static const String defaultGeminiUrl = 'https://generativelanguage.googleapis.com/v1beta/openai';
  static const String defaultNvidiaUrl = 'https://integrate.api.nvidia.com/v1';
  static const String defaultOllamaUrl = 'http://localhost:11434/v1';

  /// Every provider, configured or not, in a fixed order.
  Iterable<ModelProvider> get all => _byId.values;

  ModelProvider? byId(String id) => _byId[id];

  /// The provider [model] names, or null when its prefix names none.
  ModelProvider? of(String model) {
    final ({String provider, String model})? name = parseModelName(model);
    return name == null ? null : _byId[name.provider];
  }

  /// Builds every provider from settings; [read] returns null for a setting
  /// that is not there.
  static Providers fromSettings(String? Function(String key) read) {
    String? address(String key, [String? fallback]) => _trimmed(read(key)) ?? fallback;
    return Providers(<String, ModelProvider>{
      gemini: ModelProvider(
        id: gemini,
        label: 'Gemini',
        baseUrl: address(geminiAddressName, defaultGeminiUrl),
        apiKey: read(geminiKeyName) ?? read(googleKeyName),
        keyName: geminiKeyName,
        sendsEffort: true,
        dailyAllowance: true,
        maxAnswerTokens: 65536,
        headerTimeout: const Duration(seconds: 120),
        // Gemini sends nothing while it thinks, which on a marking request
        // can be minutes.
        idleTimeout: const Duration(seconds: 300),
        totalTimeout: const Duration(minutes: 15),
      ),
      nvidia: ModelProvider(
        id: nvidia,
        label: 'NVIDIA',
        baseUrl: address(nvidiaAddressName, defaultNvidiaUrl),
        apiKey: read(nvidiaKeyName),
        keyName: nvidiaKeyName,
        // Its free endpoints accept a JSON object but not every schema.
        jsonSchema: false,
        // A hidden daily limit: once refused twice, rest until tomorrow.
        dailyAllowance: true,
        maxAnswerTokens: 32768,
        // The free endpoints are known to hang; a short leash lets the next
        // model take over instead of the run stalling.
        headerTimeout: const Duration(seconds: 60),
        idleTimeout: const Duration(seconds: 90),
        totalTimeout: const Duration(minutes: 10),
      ),
      server: ModelProvider(
        id: server,
        label: 'GPU server',
        baseUrl: address(serverAddressName),
        apiKey: read(serverKeyName),
        keyName: serverKeyName,
        addressName: serverAddressName,
        selfHosted: true,
        needsKey: false,
        idleTimeout: const Duration(seconds: 300),
        totalTimeout: const Duration(minutes: 30),
      ),
      ollama: ModelProvider(
        id: ollama,
        label: 'This computer (Ollama)',
        baseUrl: address(ollamaAddressName, defaultOllamaUrl),
        addressName: ollamaAddressName,
        selfHosted: true,
        needsKey: false,
        // A laptop sends nothing until it has loaded the model and read the
        // prompt, which can take minutes.
        headerTimeout: const Duration(minutes: 10),
        idleTimeout: const Duration(minutes: 10),
        totalTimeout: const Duration(minutes: 60),
      ),
    });
  }

  static String? _trimmed(String? value) {
    if (value == null) return null;
    String url = value.trim();
    while (url.endsWith('/')) {
      url = url.substring(0, url.length - 1);
    }
    return url.isEmpty ? null : url;
  }
}
