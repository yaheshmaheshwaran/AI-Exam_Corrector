import 'dart:io';
import 'dart:ui' show AppExitResponse;

import 'package:flutter/material.dart';

import 'package:exam_corrector/app/app.dart';
import 'package:exam_corrector/core/config/app_config.dart';
import 'package:exam_corrector/core/errors/app_exception.dart';
import 'package:exam_corrector/pipeline/pipeline_factory.dart';
import 'package:exam_corrector/services/ai/gemini_model_client.dart';
import 'package:exam_corrector/services/ai/model_client.dart';
import 'package:exam_corrector/services/ocr/sidecar_client.dart';
import 'package:exam_corrector/services/ocr/sidecar_process_service.dart';
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

  // The only line that names a model provider.
  final ModelClient models = GeminiModelClient(liveConfig);

  final PipelineFactory pipelines = PipelineFactory(
    config: liveConfig,
    sidecar: sidecar,
    models: models,
  );

  controller = CorrectionController(config: config, pipeline: pipelines.build);

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

  runApp(ExamCorrectorApp(controller: controller));
}
