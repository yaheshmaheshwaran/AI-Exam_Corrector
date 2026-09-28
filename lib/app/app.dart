import 'package:flutter/material.dart';

import 'package:exam_corrector/app/app_colors.dart';
import 'package:exam_corrector/app/app_text.dart';
import 'package:exam_corrector/app/app_theme.dart';
import 'package:exam_corrector/screens/account/account_menu.dart';
import 'package:exam_corrector/screens/account/account_screen.dart';
import 'package:exam_corrector/screens/account/pending_screen.dart';
import 'package:exam_corrector/screens/home/home_screen.dart';
import 'package:exam_corrector/screens/launch/launch_screen.dart';
import 'package:exam_corrector/screens/student/student_screen.dart';
import 'package:exam_corrector/services/results/results_repository.dart';
import 'package:exam_corrector/state/app_session.dart';
import 'package:exam_corrector/state/appearance.dart';
import 'package:exam_corrector/state/correction_controller.dart';

/// The application shell: signing in first, then the signed-in person's
/// screen — marking for teachers and the college admin, results for
/// students. Signing out goes back to signing in; the teacher's work is kept
/// in the controller throughout.
class ExamCorrectorApp extends StatelessWidget {
  const ExamCorrectorApp({
    super.key,
    required this.controller,
    this.session,
    this.results,
    this.appearance,
    this.transparency,
    this.showLaunch = false,
  });

  final CorrectionController controller;

  /// Whether the opening screen plays over the first screen. On for the real
  /// app; off by default so tests start straight on the screen they check.
  final bool showLaunch;

  /// Light, dark or system; without one the app follows the system.
  final Appearance? appearance;

  /// Whether pinned surfaces are frosted; frosted when absent.
  final Transparency? transparency;

  /// Who is using the app; without one the app is the teacher's alone.
  final AppSession? session;

  /// The results database students read.
  final ResultsRepository? results;

  @override
  Widget build(BuildContext context) {
    final AppSession? session = this.session;
    final Appearance? appearance = this.appearance;
    final Transparency? transparency = this.transparency;
    Widget app = appearance == null
        ? _app(ThemeMode.system, session)
        : AppearanceScope(
            appearance: appearance,
            child: ValueListenableBuilder<ThemeMode>(
              valueListenable: appearance,
              builder: (BuildContext context, ThemeMode mode, _) => _app(mode, session),
            ),
          );
    if (transparency != null) app = TransparencyScope(transparency: transparency, child: app);
    return app;
  }

  Widget _app(ThemeMode mode, AppSession? session) {
    return MaterialApp(
      title: 'Marklume',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light,
      darkTheme: AppTheme.dark,
      themeMode: mode,
      // Every frosted surface reads one shared backdrop, rather than each
      // reading its own.
      builder: (BuildContext context, Widget? child) {
        final Widget grouped = BackdropGroup(child: child ?? const SizedBox.shrink());
        return showLaunch ? LaunchOverlay(child: grouped) : grouped;
      },
      home: session == null
          ? HomeScreen(controller: controller)
          : ListenableBuilder(
              listenable: session,
              builder: (BuildContext context, _) {
                final Account? account = session.account;
                return switch (session.stage) {
                  SessionStage.starting || SessionStage.signedOut => AccountScreen(session: session),
                  SessionStage.awaitingApproval || SessionStage.closed => PendingScreen(session: session),
                  SessionStage.offline => HomeScreen(controller: controller, onSwitchRole: session.signOut),
                  SessionStage.signedIn when account != null && account.role == AppRole.student => StudentScreen(
                    results: results,
                    rollNo: account.rollNo ?? '',
                    account: account,
                    onSwitchRole: session.signOut,
                  ),
                  SessionStage.signedIn => HomeScreen(
                    controller: controller,
                    onSwitchRole: session.signOut,
                    account: AccountMenu(session: session),
                  ),
                };
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
      title: 'Marklume',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light,
      darkTheme: AppTheme.dark,
      home: Builder(
        builder: (BuildContext context) => Scaffold(
          body: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 520),
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Icon(
                      Icons.error_outline,
                      size: 40,
                      color: context.colors.danger,
                    ),
                    const SizedBox(height: AppTheme.gap),
                    Text(
                      'Marklume could not start',
                      style: context.text.heading,
                    ),
                    const SizedBox(height: AppTheme.gapSmall),
                    Text(
                      message,
                      textAlign: TextAlign.center,
                      style: context.text.muted,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
