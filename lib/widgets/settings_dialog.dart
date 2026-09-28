import 'package:flutter/material.dart';

import 'package:exam_corrector/widgets/ui/app_dialog.dart';
import 'package:exam_corrector/widgets/ui/frosted.dart';

import 'package:exam_corrector/app/press_feedback.dart';

import 'package:exam_corrector/app/app_colors.dart';
import 'package:exam_corrector/app/app_text.dart';
import 'package:exam_corrector/app/app_theme.dart';
import 'package:exam_corrector/core/config/app_config.dart';
import 'package:exam_corrector/services/ui_sound.dart';
import 'package:exam_corrector/state/appearance.dart';
import 'package:exam_corrector/state/correction_controller.dart';

/// Where the teacher puts their API key.
///
/// A packaged Windows application cannot expect its user to set an environment
/// variable, so the key is typed here and saved to the user's profile. An
/// environment variable, when present, still wins — that is what the note says.
class SettingsDialog extends StatefulWidget {
  const SettingsDialog({super.key, required this.controller});

  final CorrectionController controller;

  static Future<void> show(
    BuildContext context,
    CorrectionController controller,
  ) {
    return showAppDialog<void>(
      context: context,
      builder: (_) => SettingsDialog(controller: controller),
    );
  }

  @override
  State<SettingsDialog> createState() => _SettingsDialogState();
}

class _SettingsDialogState extends State<SettingsDialog> {
  late final TextEditingController _keyField = TextEditingController(
    text: widget.controller.config.apiKey ?? '',
  );
  late final TextEditingController _modelField = TextEditingController(
    text: widget.controller.config.model,
  );
  late final TextEditingController _fallbackField = TextEditingController(
    text: widget.controller.config.fallbackModels.join(', '),
  );
  late final TextEditingController _trocrField = TextEditingController(
    text: widget.controller.config.trocrModel,
  );
  late bool _ocrEnabled = widget.controller.config.ocrEnabled;
  late bool _visionCrossCheck = widget.controller.config.visionCrossCheck;
  late double _threshold = widget.controller.config.ocrConfidenceThreshold;
  late final TextEditingController _visionModelField = TextEditingController(
    text: widget.controller.config.visionModel ?? '',
  );
  late LayoutEngine _layout = widget.controller.config.layoutEngine;
  late bool _visualAnalysis = widget.controller.config.visualAnalysis;
  late double _reviewThreshold = widget.controller.config.reviewThreshold;
  late bool _developerMode = widget.controller.config.developerMode;

  bool _obscured = true;
  bool _saving = false;

  @override
  void dispose() {
    _keyField.dispose();
    _modelField.dispose();
    _fallbackField.dispose();
    _trocrField.dispose();
    _visionModelField.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    await widget.controller.saveSettings(
      apiKey: _keyField.text,
      model: _modelField.text,
      fallbackModels: _fallbackField.text,
      ocrEnabled: _ocrEnabled,
      trocrModel: _trocrField.text,
      ocrThreshold: _threshold,
      visionCrossCheck: _visionCrossCheck,
      layoutEngine: _layout,
      visionModel: _visionModelField.text,
      reviewThreshold: _reviewThreshold,
      visualAnalysis: _visualAnalysis,
      developerMode: _developerMode,
    );
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);

    // The cross-check runs on whichever model is configured for marking, so
    // naming it here keeps the two settings visibly connected.
    final String visionModel = _modelField.text.trim().isEmpty
        ? 'the marking model'
        : _modelField.text.trim();

    return AlertDialog(
      title: const Text('Settings'),
      contentPadding: const EdgeInsets.fromLTRB(24, 8, 24, 20),
      content: SizedBox(
        width: 460,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              if (AppearanceScope.of(context)
                  case final Appearance appearance) ...<Widget>[
                Text('Appearance', style: theme.textTheme.titleSmall),
                const SizedBox(height: 6),
                // Applies at once; it is not part of what Save writes.
                SegmentedButton<ThemeMode>(
                  key: const Key('settings-appearance'),
                  showSelectedIcon: false,
                  segments: const <ButtonSegment<ThemeMode>>[
                    ButtonSegment<ThemeMode>(
                      value: ThemeMode.system,
                      icon: Icon(Icons.brightness_auto_outlined, size: 16),
                      label: Text('System'),
                    ),
                    ButtonSegment<ThemeMode>(
                      value: ThemeMode.light,
                      icon: Icon(Icons.light_mode_outlined, size: 16),
                      label: Text('Light'),
                    ),
                    ButtonSegment<ThemeMode>(
                      value: ThemeMode.dark,
                      icon: Icon(Icons.dark_mode_outlined, size: 16),
                      label: Text('Dark'),
                    ),
                  ],
                  selected: <ThemeMode>{appearance.value},
                  onSelectionChanged: (Set<ThemeMode> picked) =>
                      appearance.choose(picked.single),
                ),
                const SizedBox(height: 18),
              ],
              if (TransparencyScope.of(context) case final Transparency transparency) ...<Widget>[
                _TransparencySetting(transparency: transparency),
                const SizedBox(height: 14),
              ],
            // Applies at once, like the appearance.
              ValueListenableBuilder<bool>(
                valueListenable: UiSound.instance.enabled,
                builder: (BuildContext context, bool on, _) => Row(
                  children: <Widget>[
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          Text(
                            'Click sounds',
                            style: theme.textTheme.titleSmall,
                          ),
                          Text(
                            'A soft click when a button is pressed.',
                            style: context.text.caption,
                          ),
                        ],
                      ),
                    ),
                    Switch(
                      key: const Key('settings-sounds'),
                      value: on,
                      onChanged: toggled(UiSound.instance.setEnabled),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 18),
              Text('Gemini API key', style: theme.textTheme.titleSmall),
              const SizedBox(height: 6),
              TextField(
                key: const Key('settings-api-key'),
                controller: _keyField,
                obscureText: _obscured,
                autofocus: true,
                enabled: !_saving,
                onSubmitted: (_) => _save(),
                decoration: InputDecoration(
                  hintText: 'AIza…',
                  suffixIcon: IconButton(
                    tooltip: _obscured ? 'Show key' : 'Hide key',
                    icon: Icon(
                      _obscured
                          ? Icons.visibility_outlined
                          : Icons.visibility_off_outlined,
                      size: 16,
                    ),
                    onPressed: () => setState(() => _obscured = !_obscured),
                  ),
                ),
              ),
              const SizedBox(height: 14),
              Text('Model', style: theme.textTheme.titleSmall),
              const SizedBox(height: 6),
              TextField(
                key: const Key('settings-model'),
                controller: _modelField,
                enabled: !_saving,
                onSubmitted: (_) => _save(),
                decoration: const InputDecoration(hintText: 'gemini-3.5-flash'),
              ),
              const SizedBox(height: 14),
              Text('Fallback models', style: theme.textTheme.titleSmall),
              const SizedBox(height: 6),
              TextField(
                key: const Key('settings-fallback-models'),
                controller: _fallbackField,
                enabled: !_saving,
                onSubmitted: (_) => _save(),
                decoration: const InputDecoration(
                  hintText: 'gemini-3.5-flash, gemini-3.5-flash-lite',
                ),
              ),
              const SizedBox(height: 4),
              Text(
                'Each model has its own daily free quota. When one runs out, '
                'marking continues on the next model in this list, and the '
                'result says which model marked the paper. Leave empty to keep '
                'every paper on one model.',
                style: context.text.caption,
              ),
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: context.colors.surfaceMuted,
                  border: Border.all(color: context.colors.border),
                  borderRadius: BorderRadius.circular(AppTheme.controlRadius),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Icon(
                          Icons.info_outline,
                          size: 15,
                          color: context.colors.textMuted,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            'The key is saved to your user profile and used for '
                            'marking only. A GEMINI_API_KEY environment '
                            'variable, if one is set, takes precedence.',
                            style: context.text.caption,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    Padding(
                      padding: const EdgeInsets.only(left: 23),
                      child: SelectableText(
                        widget.controller.settingsLocation,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: context.colors.textFaint,
                          fontFamily: 'Consolas',
                          fontSize: 12,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              const Divider(),
              const SizedBox(height: 12),
              Text('Page understanding', style: theme.textTheme.titleSmall),
              const SizedBox(height: 6),
              DropdownButtonFormField<LayoutEngine>(
                key: const Key('settings-layout-engine'),
                initialValue: _layout,
                isExpanded: true,
                style: context.text.small,
                items: const <DropdownMenuItem<LayoutEngine>>[
                  DropdownMenuItem<LayoutEngine>(
                    value: LayoutEngine.hybrid,
                    child: Text(
                      'Hybrid — local first, vision model for complex pages',
                    ),
                  ),
                  DropdownMenuItem<LayoutEngine>(
                    value: LayoutEngine.vision,
                    child: Text('Vision model for every page'),
                  ),
                  DropdownMenuItem<LayoutEngine>(
                    value: LayoutEngine.local,
                    child: Text('Local only — offline, no API requests'),
                  ),
                ],
                onChanged: _saving
                    ? null
                    : (LayoutEngine? value) =>
                          setState(() => _layout = value ?? _layout),
              ),
              const SizedBox(height: 4),
              Text(
                'How each scanned page is divided into answers, diagrams, graphs, '
                'tables and equations. Hybrid sends only pages with drawings or '
                'content local analysis could not place — usually a few per script.',
                style: context.text.caption,
              ),
              const SizedBox(height: 12),
              Text('Vision model', style: theme.textTheme.titleSmall),
              const SizedBox(height: 6),
              TextField(
                key: const Key('settings-vision-model'),
                controller: _visionModelField,
                enabled: !_saving,
                decoration: InputDecoration(
                  hintText: 'Leave empty to use $visionModel',
                ),
              ),
              ToggleRow(
                child: SwitchListTile(
                  key: const Key('settings-visual-analysis'),
                  value: _visualAnalysis,
                  onChanged: toggled(
                    _saving
                        ? null
                        : (bool value) =>
                              setState(() => _visualAnalysis = value),
                  ),
                  title: const Text(
                    'Analyse diagrams, graphs, tables and equations',
                  ),
                  subtitle: Text(
                    'Their images are always kept and shown to the marker; this adds '
                    'a structured description of each.',
                    style: context.text.caption,
                  ),
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                'Flag questions marked below ${(_reviewThreshold * 100).round()}% confidence',
                style: theme.textTheme.titleSmall,
              ),
              Slider(
                key: const Key('settings-review-threshold'),
                value: _reviewThreshold,
                min: 0.3,
                max: 0.95,
                divisions: 13,
                label: '${(_reviewThreshold * 100).round()}%',
                onChanged: _saving
                    ? null
                    : (double value) =>
                          setState(() => _reviewThreshold = value),
              ),
              ToggleRow(
                child: SwitchListTile(
                  key: const Key('settings-developer-mode'),
                  value: _developerMode,
                  onChanged: toggled(
                    _saving
                        ? null
                        : (bool value) =>
                              setState(() => _developerMode = value),
                  ),
                  title: const Text('Developer mode'),
                  subtitle: Text(
                    'Adds the page inspector: every detected region, its type, '
                    'confidence, reading order and question.',
                    style: context.text.caption,
                  ),
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                ),
              ),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  key: const Key('settings-clear-cache'),
                  onPressed: _saving ? null : widget.controller.clearCache,
                  icon: const Icon(Icons.delete_sweep_outlined, size: 16),
                  label: const Text('Clear processing cache'),
                ),
              ),
              const SizedBox(height: 12),
              const Divider(),
              const SizedBox(height: 12),
              Text('Handwritten papers', style: theme.textTheme.titleSmall),
              const SizedBox(height: 6),
              Text(
                'Handwriting is read region by region by Microsoft TrOCR running '
                'on this machine. Turn this off to rely on the vision model alone.',
                style: context.text.caption,
              ),
              const SizedBox(height: 8),
              ToggleRow(
                child: SwitchListTile(
                  key: const Key('settings-ocr-enabled'),
                  value: _ocrEnabled,
                  onChanged: toggled(
                    _saving
                        ? null
                        : (bool value) => setState(() => _ocrEnabled = value),
                  ),
                  title: const Text('Read handwriting locally (TrOCR)'),
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                ),
              ),
              ToggleRow(
                child: SwitchListTile(
                  key: const Key('settings-vision-cross-check'),
                  value: _visionCrossCheck,
                  onChanged: toggled(
                    _saving
                        ? null
                        : (bool value) =>
                              setState(() => _visionCrossCheck = value),
                  ),
                  title: const Text('Double-check uncertain handwriting'),
                  subtitle: Text(
                    'Sends only the low-confidence regions to the vision model for '
                    'a second opinion. Costs API requests.',
                    style: context.text.caption,
                  ),
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                ),
              ),
              const SizedBox(height: 10),
              Text(
                'Flag handwriting below ${(_threshold * 100).round()}% confidence',
                style: theme.textTheme.titleSmall,
              ),
              Slider(
                key: const Key('settings-ocr-threshold'),
                value: _threshold,
                min: 0.5,
                max: 0.99,
                divisions: 49,
                label: '${(_threshold * 100).round()}%',
                onChanged: _saving
                    ? null
                    : (double value) => setState(() => _threshold = value),
              ),
              Text(
                'Correctly read handwriting usually scores above 95%; misread '
                'symbols and arithmetic score between 75% and 90%. Lowering this '
                'lets more mistakes through unchecked.',
                style: context.text.caption,
              ),
              const SizedBox(height: 14),
              Text('Recognition model', style: theme.textTheme.titleSmall),
              const SizedBox(height: 6),
              TextField(
                key: const Key('settings-trocr-model'),
                controller: _trocrField,
                enabled: !_saving && _ocrEnabled,
                onSubmitted: (_) => _save(),
                decoration: const InputDecoration(
                  hintText: 'microsoft/trocr-large-handwritten',
                ),
              ),
              const SizedBox(height: 4),
              Text(
                'trocr-base-handwritten is about four times faster and less '
                'accurate. Changing this downloads the new weights on first use.',
                style: context.text.caption,
              ),
            ],
          ),
        ),
      ),
      actions: <Widget>[
        OutlinedButton(
          onPressed: _saving ? null : () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _saving ? null : _save,
          child: const Text('Save'),
        ),
      ],
    );
  }
}

/// How clearly content shows through the frosted bars: a slider from Off
/// (solid surfaces, no blur) to the clearest that keeps text readable.
/// Applies as it moves, and is saved when it is let go.
class _TransparencySetting extends StatelessWidget {
  const _TransparencySetting({required this.transparency});

  final Transparency transparency;

  static String _describe(double strength) =>
      strength <= 0 ? 'Off' : '${(strength * 100).round()}%';

  @override
  Widget build(BuildContext context) {
    final double strength = transparency.value;
    final bool held = systemWantsSolid(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text('Transparency', style: Theme.of(context).textTheme.titleSmall),
                  Text(
                    held
                        ? 'Solid for now: the system asks for reduced motion or more contrast.'
                        : 'How clearly content shows through the frosted bars. Off gives solid surfaces.',
                    style: context.text.caption,
                  ),
                ],
              ),
            ),
            const SizedBox(width: 12),
            Text(
              _describe(strength),
              key: const Key('settings-transparency-value'),
              style: context.text.small.copyWith(
                fontWeight: FontWeight.w600,
                color: context.colors.text,
                fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
              ),
            ),
          ],
        ),
        Row(
          children: <Widget>[
            Text('Off', style: context.text.caption),
            Expanded(
              child: Slider(
                key: const Key('settings-transparency'),
                value: strength,
                divisions: 10,
                label: _describe(strength),
                onChanged: transparency.preview,
                onChangeEnd: (double value) {
                  UiSound.instance.play(UiSoundKind.toggle);
                  transparency.choose(value);
                },
              ),
            ),
            Text('Clear', style: context.text.caption),
          ],
        ),
      ],
    );
  }
}
