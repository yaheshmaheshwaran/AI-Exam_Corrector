import 'dart:async';
import 'dart:io';


import 'package:exam_corrector/ai/ai_settings.dart';
import 'package:exam_corrector/ai/providers.dart';
import 'package:exam_corrector/marking/marking_pipeline.dart';
import 'package:exam_corrector/features/workspace.dart';

/// Saving what the teacher set in Settings, checking a model, and clearing
/// the cache.
mixin SettingsFeature on Workspace {

  /// Whether [model] can be reached with [preview] — Settings as typed, not
  /// yet saved — and is served there.
  Future<({bool ok, String message})> checkModel(AiSettings preview, String model) => modelCheckFn(preview, model);

  // --------------------------------------------------------------------------
  // Settings
  // --------------------------------------------------------------------------

  /// Saves what the teacher typed in Settings and makes it live immediately:
  /// the next run reads the settings afresh. A value left null is unchanged.
  Future<void> saveSettings({
    String? geminiKey,
    String? nvidiaKey,
    String? prepModels,
    String? readerModels,
    String? markerModels,
    String? serverUrl,
    String? serverKey,
    String? ollamaUrl,
    double? reviewThreshold,
    bool? backgroundProcessing,
    bool? developerMode,
  }) async {
    final Providers before = aiSettings.providers;
    try {
      await settingsStore.save(
        apiKey: geminiKey,
        nvidiaKey: nvidiaKey,
        prepModels: prepModels,
        readerModels: readerModels,
        markerModels: markerModels,
        reviewThreshold: reviewThreshold,
        backgroundProcessing: backgroundProcessing,
        developerMode: developerMode,
        openModels: <String, String>{
          Providers.serverAddressName: ?serverUrl,
          Providers.serverKeyName: ?serverKey,
          Providers.ollamaAddressName: ?ollamaUrl,
        },
      );
      aiSettings = await loadAiSettings(settingsStore);
    } on Exception catch (error) {
      fail('Settings could not be saved.', 'Could not save settings: $error');
      return;
    }

    for (final ModelProvider provider in aiSettings.providers.all) {
      if (provider.apiKey != before.byId(provider.id)?.apiKey) usage?.keyChanged(provider.id);
    }

    appConfig = appConfig.copyWith(
      reviewThreshold: reviewThreshold,
      backgroundProcessing: backgroundProcessing,
      developerMode: developerMode,
    );

    if (aiSettings.hasModelAccess) {
      setStatus('Settings saved. Ready to mark with ${modelLabel(markersInUse.first)}.');
    } else {
      statusText = Workspace.notReadyMessage;
      statusError = true;
      notifyListeners();
    }
    // Background processing just switched on: ask once whether it may say
    // when it is done, and start on a class that is waiting.
    if (backgroundProcessing ?? false) {
      unawaited(backgroundSignals.requestNotifications());
      startInBackground();
    }
  }

  /// Deletes every cached stage result. Teacher reviews and corrections are
  /// kept elsewhere and survive.
  Future<void> clearCache() async {
    if (isBusy) return;
    try {
      final MarkingPipeline pipeline = pipelineOf();
      final Directory docs = Directory(
        '${pipeline.store.root.path}${Platform.pathSeparator}docs',
      );
      if (await docs.exists()) {
        await for (final FileSystemEntity entry in docs.list()) {
          if (entry is! Directory) continue;
          await for (final FileSystemEntity file in entry.list()) {
            final String name = file.path.split(RegExp(r'[/\\]')).last;
            if (name.startsWith('teacher-')) continue;
            await file.delete(recursive: true);
          }
        }
      }
      setStatus('Cache cleared. Your reviews and corrections were kept.');
    } on IOException catch (error) {
      fail('The cache could not be cleared.', '$error');
    }
  }
}
