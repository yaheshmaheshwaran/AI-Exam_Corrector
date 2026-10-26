import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:pdfrx/pdfrx.dart' show pdfrxFlutterInitialize;

import 'package:exam_corrector/ai/ai_settings.dart';
import 'package:exam_corrector/ai/llm_client.dart';
import 'package:exam_corrector/ai/provider_health.dart';
import 'package:exam_corrector/ai/usage.dart';
import 'package:exam_corrector/app/app.dart';
import 'package:exam_corrector/core/config/app_config.dart';
import 'package:exam_corrector/marking/marking_pipeline.dart';
import 'package:exam_corrector/marking/script/pages.dart';
import 'package:exam_corrector/marking/stage_store.dart';
import 'package:exam_corrector/services/window_chrome.dart';
import 'package:exam_corrector/core/errors/app_exception.dart';
import 'package:exam_corrector/services/accounts/account_repository.dart';
import 'package:exam_corrector/services/accounts/server_config.dart';
import 'package:exam_corrector/services/accounts/session_file.dart';
import 'package:exam_corrector/services/accounts/supabase_account_repository.dart';
import 'package:exam_corrector/services/results/results_repository.dart';
import 'package:exam_corrector/services/results/session_results.dart';
import 'package:exam_corrector/services/review/marking_standard_store.dart';
import 'package:exam_corrector/services/settings_store.dart';
import 'package:exam_corrector/services/ui_sound.dart';
import 'package:exam_corrector/services/syllabus/model_syllabus_structurer.dart';
import 'package:exam_corrector/services/syllabus/syllabus_library.dart';
import 'package:exam_corrector/state/app_session.dart';
import 'package:exam_corrector/state/appearance.dart';
import 'package:exam_corrector/state/correction_controller.dart';

/// Entry point: configuration → AI client → pipeline → controller → window.
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  unawaited(WindowChrome.watch());
  // PDF pages are rendered inside the app with PDFium, bundled by pdfrx.
  PageRenderer.initialize = pdfrxFlutterInitialize;

  final AppConfig config;
  try {
    config = await AppConfig.load();
  } on ConfigException catch (error) {
    runApp(StartupErrorApp(message: error.message));
    return;
  }

  // Where each model runs and which models do each job. Reading it never
  // fails: a setting that cannot be used is replaced by its default.
  final AiSettings ai = await AiSettings.load();

  // The controller owns the live settings, so a change saved in Settings is
  // picked up by the very next correction.
  late final CorrectionController controller;

  // Every request to a model is counted, and a model out of its allowance is
  // remembered until it comes back — shown to the teacher in the bar.
  final Directory? support = SettingsStore.supportDirectory();
  final UsageMonitor usage = await UsageMonitor.ofApp(
    dailyAllowance: (String model) => controller.ai.providers.of(model)?.dailyAllowance ?? false,
  );
  // Which of our own servers are unreachable (a stopped Kaggle notebook), so
  // a run moves to the next model at once instead of asking a dead server.
  final ProviderHealth health = ProviderHealth();

  // The results database — what students read and raise corrections in —
  // beside the cache. Opening it is quick; bringing in results published as
  // files before it existed waits until the window is up (below).
  SqliteResultsRepository? results;
  if (support != null) {
    try {
      results = SqliteResultsRepository.open(File('${support.path}${Platform.pathSeparator}exam_corrector.db'));
    } on Exception {
      results = null; // Marking still works; publishing is unavailable.
    }
  }

  // The college server, when one has been entered: accounts and the results
  // students see live there. Without one, a teacher marks on this computer.
  final ServerConfig? server = await ServerConfig.load();
  String inSupport(String name) => '${support!.path}${Platform.pathSeparator}$name';
  AccountRepository accountsOn(ServerConfig server) => SupabaseAccountRepository(
        server,
        sessionFile: SessionFile(support == null ? null : File(inSupport('account-session.json'))),
        pageCache: support == null ? null : Directory(inSupport('cloud-pages')),
      );
  // What the controller and screens publish to and read from: the college's
  // results once someone signs in, this computer's for a teacher without an
  // account.
  final SessionResults sessionResults = SessionResults();
  final AppSession session = AppSession(
    accounts: server == null ? null : accountsOn(server),
    server: server,
    connectTo: accountsOn,
    results: sessionResults,
    localResults: results,
  );

  // Read before the first frame so the bars never change look as it opens.
  final Transparency transparency = Transparency();
  await transparency.load();

  // The one client for every model; which server a model goes to is decided
  // by the start of its name (gemini/…, nvidia/…, server/…, ollama/…).
  final LlmClient models = LlmClient(() => controller.ai, usage: usage, health: health);

  // The cache of every stage, under the application's per-user folder.
  final StageStore store = StageStore(
    Directory('${(support ?? Directory.systemTemp).path}${Platform.pathSeparator}cache'),
    enabled: config.cacheEnabled,
  );
  final MarkingPipeline pipeline = MarkingPipeline(
    settings: () => controller.markingSettings,
    store: store,
    client: models,
  );

  controller = CorrectionController(
    config: config,
    ai: ai,
    pipeline: () => pipeline,
    // The teacher's syllabi, saved beside the cache; a layout the parser
    // cannot read is read by the model, once, when it is added.
    syllabusLibrary: SyllabusLibrary.standard(
      structurer: ModelSyllabusStructurer(models, () => controller.markingSettings),
    ),
    usage: usage,
    health: health,
    standards: support == null
        ? null
        : MarkingStandardStore(File('${support.path}${Platform.pathSeparator}marking-standards.json')),
    results: sessionResults,
  );
  // Signing in or out changes whose requests the badge counts.
  session.addListener(controller.refreshRequests);

  runApp(ExamCorrectorApp(
    controller: controller,
    session: session,
    results: sessionResults,
    transparency: transparency,
    showLaunch: true,
  ));

  // The click sound is handed to the platform once the window is up; until
  // then presses are simply silent.
  WidgetsBinding.instance.addPostFrameCallback((_) => UiSound.instance.load());

  // An account kept from last time signs back in once the window is up.
  WidgetsBinding.instance.addPostFrameCallback((_) => session.restore());

  // Old published files come in once the window is showing, so a large
  // folder never delays it.
  final SqliteResultsRepository? repository = results;
  if (repository != null && support != null) {
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      try {
        final int imported =
            await repository.importFolder(Directory('${support.path}${Platform.pathSeparator}published'));
        if (imported > 0) await controller.refreshRequests();
      } on Exception {
        // The files stay where they are and are tried again next start.
      }
    });
  }
}
