import 'package:flutter/material.dart';

import 'package:exam_corrector/app/app.dart';
import 'package:exam_corrector/core/config/app_config.dart';
import 'package:exam_corrector/core/errors/app_exception.dart';
import 'package:exam_corrector/services/ai/correction_service.dart';
import 'package:exam_corrector/services/ai/gemini_correction_service.dart';
import 'package:exam_corrector/state/correction_controller.dart';

/// Entry point: configuration → service → controller → window.
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final AppConfig config;
  try {
    config = await AppConfig.load();
  } on ConfigException catch (error) {
    runApp(StartupErrorApp(message: error.message));
    return;
  }

  // The controller owns the live configuration, so a key saved in Settings is
  // picked up by the very next correction.
  late final CorrectionController controller;
  final CorrectionService service =
      GeminiCorrectionService(() => controller.config);

  controller = CorrectionController(
    config: config,
    correctionService: service,
  );

  runApp(ExamCorrectorApp(controller: controller));
}
