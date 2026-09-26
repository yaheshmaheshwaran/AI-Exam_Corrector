import 'package:flutter/material.dart';

import 'package:exam_corrector/app/app_theme.dart';
import 'package:exam_corrector/screens/home/home_screen.dart';
import 'package:exam_corrector/screens/login/role_screen.dart';
import 'package:exam_corrector/screens/student/student_screen.dart';
import 'package:exam_corrector/services/results/results_repository.dart';
import 'package:exam_corrector/state/app_session.dart';
import 'package:exam_corrector/state/correction_controller.dart';

/// The application shell: the role picker first, then the chosen role's
/// screen. Switching role goes back to the picker; the teacher's work is
/// kept in the controller throughout.
class ExamCorrectorApp extends StatelessWidget {
  const ExamCorrectorApp({
    super.key,
    required this.controller,
    this.session,
    this.results,
  });

  final CorrectionController controller;

  /// Who is using the app; without one the app is the teacher's alone.
  final AppSession? session;

  /// The results database students read.
  final ResultsRepository? results;

  @override
  Widget build(BuildContext context) {
    final AppSession? session = this.session;
    return MaterialApp(
      title: 'Exam Corrector',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.build(),
      home: session == null
          ? HomeScreen(controller: controller)
          : ListenableBuilder(
              listenable: session,
              builder: (BuildContext context, _) => switch (session.role) {
                null => RoleScreen(onChoose: session.enter),
                AppRole.teacher => HomeScreen(controller: controller, onSwitchRole: session.leave),
                AppRole.student => StudentScreen(results: results, onSwitchRole: session.leave),
              },
            ),
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
