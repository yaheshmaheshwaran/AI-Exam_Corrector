import 'dart:io';

import 'package:flutter/material.dart';

import 'package:exam_corrector/app/app.dart';
import 'package:exam_corrector/core/config/app_config.dart';
import 'package:exam_corrector/core/errors/app_exception.dart';
import 'package:exam_corrector/services/ai/correction_service.dart';
import 'package:exam_corrector/services/ai/gemini_correction_service.dart';
import 'package:exam_corrector/services/ai/vision_transcription_service.dart';
import 'package:exam_corrector/services/ocr/ocr_service.dart';
import 'package:exam_corrector/services/ocr/sidecar_ocr_service.dart';
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
  // picked up by the very next correction — and by the next transcription.
  late final CorrectionController controller;
  AppConfig liveConfig() => controller.config;

  final CorrectionService service = GeminiCorrectionService(liveConfig);
  final OcrService ocrService = SidecarOcrService(liveConfig);

  controller = CorrectionController(
    config: config,
    correctionService: service,
    ocrService: ocrService,
    visionService: VisionTranscriptionService(liveConfig),
  );

  // The sidecar is a child process; leaving it running after the window closes
  // would strand a multi-gigabyte Python process on the teacher's machine.
  ProcessSignal.sigterm.watch().listen((_) async {
    await ocrService.dispose();
    exit(0);
  });

  runApp(ExamCorrectorApp(controller: controller));
}
