import 'package:flutter/material.dart';

import 'package:exam_corrector/app/app_theme.dart';
import 'package:exam_corrector/screens/home/home_screen.dart';
import 'package:exam_corrector/state/correction_controller.dart';

/// The application shell. One window, one workflow — there is nothing to route
/// between, so the shell hands the controller straight to the screen.
class ExamCorrectorApp extends StatelessWidget {
  const ExamCorrectorApp({super.key, required this.controller});

  final CorrectionController controller;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Exam Corrector',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.build(),
      home: HomeScreen(controller: controller),
    );
  }
}

/// Shown when the application cannot start at all — a bad configuration value,
/// for example. The teacher gets the reason rather than a closed window.
class StartupErrorApp extends StatelessWidget {
  const StartupErrorApp({super.key, required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Exam Corrector',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.build(),
      home: Scaffold(
        body: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 520),
            child: Padding(
              padding: const EdgeInsets.all(32),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  const Icon(Icons.error_outline,
                      size: 44, color: AppTheme.danger),
                  const SizedBox(height: AppTheme.gap),
                  Text(
                    'Exam Corrector could not start',
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                  const SizedBox(height: 8),
                  Text(message, textAlign: TextAlign.center),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
