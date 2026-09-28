import 'dart:io';
import 'dart:ui' show AppExitResponse;

import 'package:flutter/material.dart';

import 'package:exam_corrector/app/app.dart';
import 'package:exam_corrector/core/config/app_config.dart';
import 'package:exam_corrector/core/errors/app_exception.dart';
import 'package:exam_corrector/pipeline/pipeline_factory.dart';
import 'package:exam_corrector/services/ai/gemini_model_client.dart';
import 'package:exam_corrector/services/ai/model_client.dart';
import 'package:exam_corrector/services/ai/model_usage.dart';
import 'package:exam_corrector/services/accounts/account_repository.dart';
import 'package:exam_corrector/services/accounts/server_config.dart';
import 'package:exam_corrector/services/accounts/session_file.dart';
import 'package:exam_corrector/services/accounts/supabase_account_repository.dart';
import 'package:exam_corrector/services/ocr/sidecar_client.dart';
import 'package:exam_corrector/services/ocr/sidecar_process_service.dart';
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

/// Entry point: configuration → engines → pipeline → controller → window.
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final AppConfig config;
  try {
    config = await AppConfig.load();
  } on ConfigException catch (error) {
    runApp(StartupErrorApp(message: error.message));
    return;
  }

  // The controller owns the live configuration, so a change saved in Settings
  // is picked up by the very next correction.
  late final CorrectionController controller;
  AppConfig liveConfig() => controller.config;

  final SidecarProcessService process = SidecarProcessService(
    externalEndpoint: () {
      final String? url = liveConfig().ocrEndpoint;
      if (url == null) return null;
      return SidecarEndpoint(
        baseUrl: Uri.parse(url.endsWith('/') ? url : '$url/'),
        token: liveConfig().ocrToken ?? '',
      );
    },
  );
  final SidecarClient sidecar = SidecarClient(process: process);

  // Every request to the model is counted, and a model out of quota is
  // remembered until its allowance resets — shown to the teacher in the bar.
  final Directory? support = SettingsStore.supportDirectory();
  final ModelUsageMonitor usage = ModelUsageMonitor(
    file: support == null ? null : File('${support.path}${Platform.pathSeparator}model-usage.json'),
  );
  await usage.load();

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

  // Read before the first frame so the window never opens in the wrong theme.
  final Appearance appearance = Appearance();
  await appearance.load();
  final Transparency transparency = Transparency();
  await transparency.load();

  // The only line that names a model provider.
  final ModelClient models = GeminiModelClient(liveConfig, usage: usage);

  final PipelineFactory pipelines = PipelineFactory(
    config: liveConfig,
    sidecar: sidecar,
    models: models,
  );

  controller = CorrectionController(
    config: config,
    pipeline: pipelines.build,
    // The teacher's syllabi, saved beside the cache; a layout the parser
    // cannot read is read by the model, once, when it is added.
    syllabusLibrary: SyllabusLibrary.standard(
      structurer: ModelSyllabusStructurer(models, liveConfig),
    ),
    usage: usage,
    standards: support == null
        ? null
        : MarkingStandardStore(File('${support.path}${Platform.pathSeparator}marking-standards.json')),
    results: sessionResults,
  );
  // Signing in or out changes whose requests the badge counts.
  session.addListener(controller.refreshRequests);

  // The sidecar is a child process; leaving it running after the window closes
  // would strand a multi-gigabyte Python process on the teacher's machine.
  // Closing the window asks the app to exit on every desktop platform, and the
  // sidecar is stopped first. A kill that skips all of this is covered by the
  // sidecar itself, which exits when this process is gone.
  // The binding keeps the listener registered for the life of the app.
  AppLifecycleListener(
    onExitRequested: () async {
      await sidecar.dispose();
      return AppExitResponse.exit;
    },
  );
  // Dart cannot watch SIGTERM on Windows; elsewhere it is how a session
  // logout or `kill` arrives.
  if (!Platform.isWindows) {
    ProcessSignal.sigterm.watch().listen((_) async {
      await sidecar.dispose();
      exit(0);
    });
  }

  runApp(ExamCorrectorApp(
    controller: controller,
    session: session,
    results: sessionResults,
    appearance: appearance,
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
