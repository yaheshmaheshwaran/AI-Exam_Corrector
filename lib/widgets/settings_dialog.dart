import 'package:flutter/material.dart';

import 'package:exam_corrector/app/app_theme.dart';
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
    return showDialog<void>(
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

  bool _obscured = true;
  bool _saving = false;

  @override
  void dispose() {
    _keyField.dispose();
    _modelField.dispose();
    _fallbackField.dispose();
    _trocrField.dispose();
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
    );
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);

    // The cross-check runs on whichever model is configured for marking, so
    // naming it here keeps the two settings visibly connected.
    final String visionModel =
        _modelField.text.trim().isEmpty ? 'the marking model' : _modelField.text.trim();

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
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: AppTheme.textSecondary),
            ),
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: AppTheme.pageBackground,
                border: Border.all(color: AppTheme.stroke),
                borderRadius: BorderRadius.circular(AppTheme.controlRadius),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      const Icon(Icons.info_outline,
                          size: 15, color: AppTheme.textSecondary),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          'The key is saved to your user profile and used for '
                          'marking only. A GEMINI_API_KEY environment '
                          'variable, if one is set, takes precedence.',
                          style: theme.textTheme.bodySmall
                              ?.copyWith(color: AppTheme.textSecondary),
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
                        color: AppTheme.textDisabled,
                        fontFamily: 'Consolas',
                        fontSize: 11,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            const Divider(),
            const SizedBox(height: 12),
            Text('Handwritten papers', style: theme.textTheme.titleSmall),
            const SizedBox(height: 6),
            Text(
              'A scan or photograph with no text layer is read by Microsoft '
              'TrOCR running on this machine. Turn this off to reject such '
              'papers instead.',
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: AppTheme.textSecondary),
            ),
            const SizedBox(height: 8),
            SwitchListTile(
              key: const Key('settings-ocr-enabled'),
              value: _ocrEnabled,
              onChanged: _saving
                  ? null
                  : (bool value) => setState(() => _ocrEnabled = value),
              title: const Text('Read handwriting'),
              contentPadding: EdgeInsets.zero,
              dense: true,
            ),
            SwitchListTile(
              key: const Key('settings-vision-cross-check'),
              value: _visionCrossCheck,
              onChanged: _saving || !_ocrEnabled
                  ? null
                  : (bool value) => setState(() => _visionCrossCheck = value),
              title: const Text('Double-check uncertain lines'),
              subtitle: Text(
                'Sends only the low-confidence line images to $visionModel '
                'for a second opinion. Costs API requests.',
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: AppTheme.textSecondary),
              ),
              contentPadding: EdgeInsets.zero,
              dense: true,
            ),
            const SizedBox(height: 10),
            Text(
              'Flag lines below ${(_threshold * 100).round()}% confidence',
              style: theme.textTheme.titleSmall,
            ),
            Slider(
              key: const Key('settings-ocr-threshold'),
              value: _threshold,
              min: 0.5,
              max: 0.99,
              divisions: 49,
              label: '${(_threshold * 100).round()}%',
              onChanged: _saving || !_ocrEnabled
                  ? null
                  : (double value) => setState(() => _threshold = value),
            ),
            Text(
              'Correctly read handwriting usually scores above 95%; misread '
              'symbols and arithmetic score between 75% and 90%. Lowering this '
              'lets more mistakes through unchecked.',
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: AppTheme.textSecondary),
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
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: AppTheme.textSecondary),
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
