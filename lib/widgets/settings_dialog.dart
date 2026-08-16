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
  bool _obscured = true;
  bool _saving = false;

  @override
  void dispose() {
    _keyField.dispose();
    _modelField.dispose();
    _fallbackField.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    await widget.controller.saveSettings(
      apiKey: _keyField.text,
      model: _modelField.text,
      fallbackModels: _fallbackField.text,
    );
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);

    return AlertDialog(
      title: const Text('Settings'),
      contentPadding: const EdgeInsets.fromLTRB(24, 8, 24, 20),
      content: SizedBox(
        width: 460,
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
          ],
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
