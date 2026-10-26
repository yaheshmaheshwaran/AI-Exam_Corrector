import 'package:flutter/material.dart';

import 'package:exam_corrector/shared/ui/app_dialog.dart';
import 'package:exam_corrector/shared/ui/app_segmented.dart';
import 'package:exam_corrector/shared/ui/frosted.dart';

import 'package:exam_corrector/app/press_feedback.dart';

import 'package:exam_corrector/app/app_colors.dart';
import 'package:exam_corrector/app/app_glass.dart';
import 'package:exam_corrector/app/app_text.dart';
import 'package:exam_corrector/app/app_theme.dart';
import 'package:exam_corrector/ai/ai_settings.dart';
import 'package:exam_corrector/ai/model_roles.dart';
import 'package:exam_corrector/ai/provider_health.dart';
import 'package:exam_corrector/ai/providers.dart';
import 'package:exam_corrector/app/observable_listenable.dart';
import 'package:exam_corrector/core/config/app_config.dart';
import 'package:exam_corrector/services/ui_sound.dart';
import 'package:exam_corrector/state/appearance.dart';
import 'package:exam_corrector/state/correction_controller.dart';

/// Where the teacher sets up the AI: their keys, which models do each job,
/// and where their own servers are — and how marking behaves.
///
/// A packaged application cannot expect its user to set an environment
/// variable, so keys are typed here and saved to the user's profile. An
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
  AiSettings get _ai => widget.controller.ai;
  AppConfig get _config => widget.controller.config;

  late final TextEditingController _geminiKey =
      TextEditingController(text: _ai.providers.byId(Providers.gemini)?.apiKey ?? '');
  late final TextEditingController _nvidiaKey =
      TextEditingController(text: _ai.providers.byId(Providers.nvidia)?.apiKey ?? '');
  late final Map<ModelRole, TextEditingController> _jobs = <ModelRole, TextEditingController>{
    for (final ModelRole role in ModelRole.values) role: TextEditingController(text: _ai.roles.chain(role).join(', ')),
  };
  late final TextEditingController _serverUrl =
      TextEditingController(text: _ai.providers.byId(Providers.server)?.baseUrl ?? '');
  late final TextEditingController _serverKey =
      TextEditingController(text: _ai.providers.byId(Providers.server)?.apiKey ?? '');
  late final TextEditingController _ollamaUrl =
      TextEditingController(text: _ai.providers.byId(Providers.ollama)?.baseUrl ?? Providers.defaultOllamaUrl);

  late bool _background = _config.backgroundProcessing;
  late double _reviewThreshold = _config.reviewThreshold;
  late bool _developerMode = _config.developerMode;

  /// What Test connection last said for each job, and whether it was good
  /// news.
  Map<ModelRole, ({bool ok, String message})> _checks = <ModelRole, ({bool ok, String message})>{};
  bool _checking = false;

  bool _obscured = true;
  bool _saving = false;

  /// Which part of the settings is showing. Fields keep what was typed as
  /// the teacher moves between parts; Save writes them all.
  _Section _section = _Section.models;

  @override
  void dispose() {
    for (final TextEditingController field in <TextEditingController>[
      _geminiKey,
      _nvidiaKey,
      ..._jobs.values,
      _serverUrl,
      _serverKey,
      _ollamaUrl,
    ]) {
      field.dispose();
    }
    super.dispose();
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    await widget.controller.saveSettings(
      geminiKey: _geminiKey.text,
      nvidiaKey: _nvidiaKey.text,
      prepModels: _jobs[ModelRole.prep]!.text,
      readerModels: _jobs[ModelRole.reader]!.text,
      markerModels: _jobs[ModelRole.marker]!.text,
      serverUrl: _serverUrl.text,
      serverKey: _serverKey.text,
      ollamaUrl: _ollamaUrl.text,
      reviewThreshold: _reviewThreshold,
      backgroundProcessing: _background,
      developerMode: _developerMode,
    );
    if (mounted) Navigator.of(context).pop();
  }

  /// The settings as typed, before they are saved.
  AiSettings get _preview => AiSettings.fromMap(<String, String>{
        Providers.geminiKeyName: _geminiKey.text,
        Providers.nvidiaKeyName: _nvidiaKey.text,
        Providers.serverAddressName: _serverUrl.text,
        Providers.serverKeyName: _serverKey.text,
        Providers.ollamaAddressName: _ollamaUrl.text,
        for (final ModelRole role in ModelRole.values) role.settingName: _jobs[role]!.text,
      });

  /// Checks the first model of every job, as typed.
  Future<void> _testConnection() async {
    setState(() {
      _checking = true;
      _checks = <ModelRole, ({bool ok, String message})>{};
    });
    final AiSettings preview = _preview;
    final Map<ModelRole, ({bool ok, String message})> results = <ModelRole, ({bool ok, String message})>{};
    for (final ModelRole role in ModelRole.values) {
      final List<String> models = preview.roles.chain(role);
      if (models.isEmpty) continue;
      results[role] = await widget.controller.checkModel(preview, models.first);
    }
    if (!mounted) return;
    setState(() {
      _checking = false;
      _checks = results;
    });
  }

  @override
  Widget build(BuildContext context) {
    final List<Widget> section = switch (_section) {
      _Section.models => _models(context),
      _Section.marking => _marking(context),
      _Section.look => _lookAndSound(context),
    };

    return AlertDialog(
      title: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          const Text('Settings'),
          const SizedBox(height: 12),
          AppSegmented<_Section>(
            key: const Key('settings-section'),
            segments: <({_Section value, String label, Key? key})>[
              for (final _Section s in _Section.values)
                (value: s, label: s.label, key: Key('settings-section-${s.name}')),
            ],
            selected: _section,
            onChanged: (_Section s) => setState(() => _section = s),
          ),
        ],
      ),
      contentPadding: const EdgeInsets.fromLTRB(24, 4, 24, 20),
      content: SizedBox(
        width: 520,
        height: 460,
        child: SingleChildScrollView(
          key: ValueKey<_Section>(_section),
          // Each part is one group of rows on a sheet of glass.
          child: Container(
            padding: const EdgeInsets.all(14),
            decoration: AppGlass.card(radius: 14, fill: Colors.white.withValues(alpha: 0.6)),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: section,
            ),
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

  static String _jobCaption(ModelRole role) => switch (role) {
        ModelRole.prep => 'Once per exam: reads the question paper and writes the answer key every script '
            'is marked against.',
        ModelRole.reader => 'Every student: reads each page — handwriting, diagrams and equations.',
        ModelRole.marker => 'Every student: marks the answers against the key. One model marks a whole '
            'script; marks by a backup are flagged for your review.',
      };

  /// The keys, which models do each job, and where our own servers are.
  List<Widget> _models(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return <Widget>[
      Text(
        'Each job uses its first model; the others are backups, used in order when one is out of '
        'its allowance or not answering. A name starts with where the model runs: gemini/, '
        'nvidia/, server/ (your GPU server) or ollama/ (this computer).',
        style: context.text.caption,
      ),
      const SizedBox(height: 12),
      _secret(const Key('settings-api-key'), _geminiKey, 'Gemini API key', 'Paste the key from AI Studio'),
      _secret(const Key('settings-nvidia-key'), _nvidiaKey, 'NVIDIA API key', 'nvapi-…'),
      const SizedBox(height: 6),
      for (final ModelRole role in ModelRole.values) ...<Widget>[
        Text(role.label[0].toUpperCase() + role.label.substring(1), style: theme.textTheme.titleSmall),
        const SizedBox(height: 6),
        TextField(
          key: Key('settings-models-${role.name}'),
          controller: _jobs[role],
          enabled: !_saving,
          onSubmitted: (_) => _save(),
          decoration: InputDecoration(hintText: ModelRoles.defaults.chain(role).join(', ')),
        ),
        const SizedBox(height: 4),
        Text(_jobCaption(role), style: context.text.caption),
        if (_checks[role] case final ({bool ok, String message}) check) ...<Widget>[
          const SizedBox(height: 4),
          Row(
            key: Key('settings-test-result-${role.name}'),
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Icon(
                check.ok ? Icons.check_circle_outline : Icons.error_outline,
                size: 15,
                color: check.ok ? context.colors.success : context.colors.danger,
              ),
              const SizedBox(width: 6),
              Expanded(child: SelectableText(check.message, style: context.text.caption)),
            ],
          ),
        ],
        const SizedBox(height: 12),
      ],
      Row(
        children: <Widget>[
          OutlinedButton.icon(
            key: const Key('settings-test-connection'),
            onPressed: _saving || _checking ? null : _testConnection,
            icon: _checking
                ? const SizedBox.square(dimension: 14, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.wifi_tethering, size: 16),
            label: const Text('Test connection'),
          ),
        ],
      ),
      const SizedBox(height: 14),
      Text('Your own servers', style: theme.textTheme.titleSmall),
      const SizedBox(height: 6),
      _field(const Key('settings-server-url'), _serverUrl, 'GPU server address',
          'https://….trycloudflare.com/v1 (Kaggle) or http://192.168.1.20:8000/v1'),
      _secret(const Key('settings-server-key'), _serverKey, 'GPU server key', 'Only if the server asks for one'),
      if (widget.controller.health case final ProviderHealth health)
        ListenableBuilder(
          listenable: health.listenable,
          builder: (BuildContext context, _) => _ServerStatusLine(status: health.statusOf(Providers.server)),
        ),
      _field(const Key('settings-ollama-url'), _ollamaUrl, 'Ollama address on this computer', Providers.defaultOllamaUrl),
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
                Icon(Icons.info_outline, size: 15, color: context.colors.textMuted),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Keys and addresses are saved to your user profile. Environment variables, if set, '
                    'take precedence.',
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
    ];
  }

  /// When marking runs, when a mark goes to the teacher, and developer tools.
  List<Widget> _marking(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return <Widget>[
      ToggleRow(
        child: SwitchListTile(
          key: const Key('settings-background'),
          value: _background,
          onChanged: toggled(_saving ? null : (bool value) => setState(() => _background = value)),
          title: const Text('Mark in the background'),
          subtitle: Text(
            'Marking starts by itself once the scripts and the question paper are in, and you can '
            'keep working meanwhile. This computer stays awake until it is done, and you are told '
            'when it finishes.',
            style: context.text.caption,
          ),
          contentPadding: EdgeInsets.zero,
          dense: true,
        ),
      ),
      const SizedBox(height: 10),
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
        onChanged: _saving ? null : (double value) => setState(() => _reviewThreshold = value),
      ),
      ToggleRow(
        child: SwitchListTile(
          key: const Key('settings-developer-mode'),
          value: _developerMode,
          onChanged: toggled(_saving ? null : (bool value) => setState(() => _developerMode = value)),
          title: const Text('Developer mode'),
          subtitle: Text(
            'Adds the page inspector: every part the reader found on each page, its type, confidence, '
            'reading order and question.',
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
    ];
  }

  /// Glass blur and sounds. Both apply at once; they are not part of what
  /// Save writes.
  List<Widget> _lookAndSound(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return <Widget>[
      if (TransparencyScope.of(context) case final Transparency transparency) ...<Widget>[
        _GlassBlurSetting(transparency: transparency),
        const SizedBox(height: 10),
      ],
      ValueListenableBuilder<bool>(
        valueListenable: UiSound.instance.enabled,
        builder: (BuildContext context, bool on, _) => Row(
          children: <Widget>[
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text('Click sounds', style: theme.textTheme.titleSmall),
                  Text('A soft click when a button is pressed.', style: context.text.caption),
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
    ];
  }

  Widget _field(Key key, TextEditingController controller, String label, String hint) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: TextField(
          key: key,
          controller: controller,
          enabled: !_saving,
          onSubmitted: (_) => _save(),
          decoration: InputDecoration(labelText: label, hintText: hint),
        ),
      );

  Widget _secret(Key key, TextEditingController controller, String label, String hint) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: TextField(
          key: key,
          controller: controller,
          obscureText: _obscured,
          enabled: !_saving,
          onSubmitted: (_) => _save(),
          decoration: InputDecoration(
            labelText: label,
            hintText: hint,
            suffixIcon: IconButton(
              tooltip: _obscured ? 'Show keys' : 'Hide keys',
              icon: Icon(_obscured ? Icons.visibility_outlined : Icons.visibility_off_outlined, size: 16),
              onPressed: () => setState(() => _obscured = !_obscured),
            ),
          ),
        ),
      );
}

/// The parts of Settings, in the order they are shown.
enum _Section {
  models('Models'),
  marking('Marking'),
  look('Look & sound');

  const _Section(this.label);

  final String label;
}

/// Whether the floating glass bars blur what passes under them. Applies and
/// is saved at once.
class _GlassBlurSetting extends StatelessWidget {
  const _GlassBlurSetting({required this.transparency});

  final Transparency transparency;

  @override
  Widget build(BuildContext context) {
    final bool held = systemWantsSolid(context);
    return ToggleRow(
      child: SwitchListTile(
        key: const Key('settings-glass-blur'),
        value: transparency.value > 0,
        onChanged: toggled((bool on) => transparency.choose(on ? 1 : 0)),
        title: const Text('Glass blur'),
        subtitle: Text(
          held
              ? 'Solid for now: the system asks for reduced motion or more contrast.'
              : 'Blurs content under the bars and behind dialogs. Uses more graphics '
                  'power; turn it off on slower computers.',
          style: context.text.caption,
        ),
        contentPadding: EdgeInsets.zero,
        dense: true,
      ),
    );
  }
}

/// Whether the GPU server answered during this session, and why not.
class _ServerStatusLine extends StatelessWidget {
  const _ServerStatusLine({required this.status});

  final ServerStatus status;

  @override
  Widget build(BuildContext context) {
    final AppColors c = context.colors;
    final (Color colour, String text) = switch (status.state) {
      ServerState.up => (c.success, 'The GPU server is answering.'),
      ServerState.down => (c.textFaint, 'The GPU server is not answering (${status.reason}). The next model in each '
          'job carries on; the server is checked again before each script.'),
      ServerState.unknown => (c.textFaint, 'The GPU server has not been used yet this session.'),
    };
    return Padding(
      key: const Key('settings-server-status'),
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.only(top: 5),
            child: Container(width: 8, height: 8, decoration: BoxDecoration(color: colour, shape: BoxShape.circle)),
          ),
          const SizedBox(width: 8),
          Expanded(child: Text(text, style: context.text.caption)),
        ],
      ),
    );
  }
}
