import 'dart:async';

import 'package:flutter/material.dart';

import 'package:exam_corrector/widgets/ui/app_dialog.dart';

import 'package:exam_corrector/app/app_colors.dart';
import 'package:exam_corrector/app/app_text.dart';
import 'package:exam_corrector/app/app_theme.dart';
import 'package:exam_corrector/core/config/app_config.dart';
import 'package:exam_corrector/services/ai/model_usage.dart';

/// What the AI is doing, in one line: at work, waiting out a rate limit, out
/// of quota for the day, or idle with today's count of requests.
enum ModelState { noKey, working, waiting, degraded, exhausted, idle }

/// The model's state as the teacher should read it.
class ModelStatus {
  const ModelStatus(this.state, this.short, this.long, {this.call});

  final ModelState state;

  /// For the bar.
  final String short;

  /// For the details.
  final String long;
  final ModelCall? call;

  static ModelStatus of(AppConfig config, ModelUsageMonitor usage) {
    final DateTime now = usage.now;
    final List<String> chain = config.modelChain;
    if (!config.hasApiKey) {
      return const ModelStatus(ModelState.noKey, 'No API key',
          'No API key is set, so nothing can be sent to the AI. Open Settings to add one.');
    }
    final ModelCall? call = usage.active;
    if (call != null && call.status == ModelCallStatus.waiting && call.retryAt != null) {
      final int seconds = call.retryAt!.difference(now).inSeconds.clamp(0, 999);
      return ModelStatus(
        ModelState.waiting,
        'Rate limited · retrying in ${seconds}s',
        '${call.model} refused the ${call.purpose} for now — ${call.message} '
            'Trying again in ${seconds}s.',
        call: call,
      );
    }
    if (call != null) {
      final int seconds = call.elapsed(now).inSeconds;
      return ModelStatus(
        ModelState.working,
        'AI: ${call.purpose} · ${_duration(seconds)}',
        '${call.model} is working on the ${call.purpose} (${_duration(seconds)} so far'
            '${call.attempts > 1 ? ', attempt ${call.attempts}' : ''}).',
        call: call,
      );
    }
    final List<String> out = <String>[for (final String m in chain) if (usage.isExhausted(m)) m];
    if (chain.isNotEmpty && out.length == chain.length) {
      final DateTime reset = out
          .map((String m) => usage.exhaustedUntil(m)!)
          .reduce((DateTime a, DateTime b) => a.isBefore(b) ? a : b);
      return ModelStatus(
        ModelState.exhausted,
        'Out of quota · back at ${clock(reset)}',
        'Every configured model is out of quota, so marking and syllabus reading '
            'cannot use the AI until ${clock(reset)}. Add another model in '
            'Settings, or use a key with a higher limit.',
      );
    }
    if (out.isNotEmpty) {
      final String using = chain.firstWhere((String m) => !out.contains(m));
      return ModelStatus(
        ModelState.degraded,
        '${out.first} out of quota · using $using',
        '${out.join(', ')} ${out.length == 1 ? 'is' : 'are'} out of quota for today; '
            'requests go to $using instead.',
      );
    }
    final int requests = usage.requestsToday;
    return ModelStatus(
      ModelState.idle,
      '${chain.isEmpty ? 'No model' : chain.first} · $requests request${requests == 1 ? '' : 's'} today',
      'The AI is idle. $requests request${requests == 1 ? ' has' : 's have'} been sent today.',
    );
  }

  static String _duration(int seconds) =>
      seconds < 60 ? '${seconds}s' : '${seconds ~/ 60}m ${(seconds % 60).toString().padLeft(2, '0')}s';

  /// "12:30 PM", in local time.
  static String clock(DateTime time, {bool seconds = false}) {
    final DateTime local = time.toLocal();
    final int hour = local.hour % 12 == 0 ? 12 : local.hour % 12;
    final String minute = local.minute.toString().padLeft(2, '0');
    final String second = seconds ? ':${local.second.toString().padLeft(2, '0')}' : '';
    return '$hour:$minute$second ${local.hour < 12 ? 'AM' : 'PM'}';
  }
}

/// The bar's indicator of model usage; opens the details.
class ModelUsageIndicator extends StatefulWidget {
  const ModelUsageIndicator({super.key, required this.config, required this.usage});

  final AppConfig config;
  final ModelUsageMonitor usage;

  @override
  State<ModelUsageIndicator> createState() => _ModelUsageIndicatorState();
}

class _ModelUsageIndicatorState extends State<ModelUsageIndicator> {
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    widget.usage.addListener(_changed);
    _changed();
  }

  @override
  void didUpdateWidget(ModelUsageIndicator old) {
    super.didUpdateWidget(old);
    if (old.usage != widget.usage) {
      old.usage.removeListener(_changed);
      widget.usage.addListener(_changed);
    }
  }

  @override
  void dispose() {
    widget.usage.removeListener(_changed);
    _tick?.cancel();
    super.dispose();
  }

  /// Ticks once a second while a request runs, so its time and any
  /// countdown stay current.
  void _changed() {
    final bool busy = widget.usage.active != null;
    if (busy && _tick == null) {
      _tick = Timer.periodic(const Duration(seconds: 1), (_) {
        if (mounted) setState(() {});
      });
    } else if (!busy) {
      _tick?.cancel();
      _tick = null;
    }
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final ModelStatus status = ModelStatus.of(widget.config, widget.usage);
    final (Color colour, Color fill, Color edge) = switch (status.state) {
      ModelState.noKey || ModelState.degraded || ModelState.waiting =>
        (context.colors.warning, context.colors.warningFill, context.colors.warningBorder),
      ModelState.exhausted => (context.colors.danger, context.colors.dangerFill, context.colors.dangerBorder),
      ModelState.working => (context.colors.primary, context.colors.primarySoft, context.colors.primaryBorder),
      ModelState.idle => (context.colors.textMuted, context.colors.surfaceMuted, context.colors.border),
    };
    final IconData icon = switch (status.state) {
      ModelState.noKey => Icons.key_off_outlined,
      ModelState.waiting => Icons.hourglass_top,
      ModelState.exhausted => Icons.block,
      ModelState.degraded => Icons.swap_horiz,
      ModelState.working || ModelState.idle => Icons.auto_awesome_outlined,
    };

    return Tooltip(
      message: '${status.long}\nClick for model usage.',
      child: InkWell(
        key: const Key('model-usage'),
        borderRadius: BorderRadius.circular(AppTheme.controlRadius),
        onTap: () => ModelUsageDialog.show(context, widget.config, widget.usage),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
          decoration: BoxDecoration(
            color: fill,
            border: Border.all(color: edge),
            borderRadius: BorderRadius.circular(AppTheme.controlRadius),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              if (status.state == ModelState.working)
                SizedBox(
                  width: 11,
                  height: 11,
                  child: CircularProgressIndicator(strokeWidth: 1.6, color: colour),
                )
              else
                Icon(icon, size: 13, color: colour),
              const SizedBox(width: 6),
              Flexible(
                child: Text(
                  status.short,
                  key: const Key('model-usage-text'),
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 12, color: colour),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Today's use of each model, their limits, and the latest requests.
class ModelUsageDialog extends StatelessWidget {
  const ModelUsageDialog({super.key, required this.config, required this.usage});

  final AppConfig config;
  final ModelUsageMonitor usage;

  static Future<void> show(BuildContext context, AppConfig config, ModelUsageMonitor usage) =>
      showAppDialog<void>(
        context: context,
        builder: (BuildContext context) => ModelUsageDialog(config: config, usage: usage),
      );

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return ListenableBuilder(
      listenable: usage,
      builder: (BuildContext context, _) {
        final ModelStatus status = ModelStatus.of(config, usage);
        final Map<String, ModelDayUsage> today = usage.today;
        final List<String> models = <String>[
          ...config.modelChain,
          for (final String m in today.keys)
            if (!config.modelChain.contains(m)) m,
        ];
        final TextStyle? head = theme.textTheme.bodySmall
            ?.copyWith(color: context.colors.textMuted, fontWeight: FontWeight.w600);
        final TextStyle? cell = theme.textTheme.bodySmall;

        return AlertDialog(
          title: const Text('Model usage'),
          content: SizedBox(
            width: 640,
            height: 460,
            child: ListView(
              children: <Widget>[
                Text(status.long, key: const Key('model-usage-status'), style: theme.textTheme.bodyMedium),
                const SizedBox(height: 6),
                Text(
                  'Counted per Google day, which resets at midnight Pacific time — '
                  '${ModelStatus.clock(ModelUsageMonitor.nextQuotaReset(usage.now))} your time. '
                  'Free-tier keys allow a limited number of requests per minute and per '
                  'day for each model; when one runs out, the next model in Settings is used.',
                  style: context.text.caption,
                ),
                const SizedBox(height: 14),
                Text('Today, by model', style: theme.textTheme.titleSmall),
                const SizedBox(height: 6),
                Table(
                  columnWidths: const <int, TableColumnWidth>{
                    0: FlexColumnWidth(3),
                    1: FlexColumnWidth(1.2),
                    2: FlexColumnWidth(1),
                    3: FlexColumnWidth(1.4),
                    4: FlexColumnWidth(3),
                  },
                  children: <TableRow>[
                    TableRow(children: <Widget>[
                      Text('Model', style: head),
                      Text('Requests', style: head),
                      Text('Failed', style: head),
                      Text('Rate limited', style: head),
                      Text('Status', style: head),
                    ]),
                    for (final String model in models)
                      TableRow(children: <Widget>[
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 4),
                          child: Text(
                            '$model${config.modelChain.isNotEmpty && config.modelChain.first == model ? '  (main)' : ''}',
                            style: cell,
                          ),
                        ),
                        Text('${today[model]?.requests ?? 0}', key: ValueKey<String>('usage-requests-$model'), style: cell),
                        Text('${today[model]?.failures ?? 0}', style: cell),
                        Text('${today[model]?.rateLimited ?? 0}', style: cell),
                        Text(
                          switch (usage.exhaustedUntil(model)) {
                            final DateTime until => 'Out of quota until ${ModelStatus.clock(until)}',
                            null => usage.active?.model == model ? 'In use now' : 'Available',
                          },
                          style: cell?.copyWith(
                            color: usage.isExhausted(model) ? context.colors.danger : null,
                          ),
                        ),
                      ]),
                  ],
                ),
                const SizedBox(height: 16),
                Text('Latest requests', style: theme.textTheme.titleSmall),
                const SizedBox(height: 4),
                if (usage.recent.isEmpty)
                  Text('None since the app started.',
                      style: context.text.caption),
                for (final ModelCall call in usage.recent) _CallRow(call: call, now: usage.now),
              ],
            ),
          ),
          actions: <Widget>[
            FilledButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Close')),
          ],
        );
      },
    );
  }
}

class _CallRow extends StatelessWidget {
  const _CallRow({required this.call, required this.now});

  final ModelCall call;
  final DateTime now;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final (IconData icon, Color colour, String result) = switch (call.status) {
      ModelCallStatus.running => (Icons.more_horiz, context.colors.primary, 'working'),
      ModelCallStatus.waiting => (Icons.hourglass_top, context.colors.warning, 'waiting out a rate limit'),
      ModelCallStatus.succeeded => (Icons.check_circle_outline, context.colors.success, 'done'),
      ModelCallStatus.failed => (Icons.error_outline, context.colors.danger, 'failed'),
    };
    final int seconds = call.elapsed(now).inSeconds;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Icon(icon, size: 15, color: colour),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  '${ModelStatus.clock(call.startedAt, seconds: true)} · ${call.purpose} · ${call.model} · '
                  '$result in ${seconds}s'
                  '${call.attempts > 1 ? ' · ${call.attempts} attempts' : ''}',
                  style: theme.textTheme.bodySmall,
                ),
                if (call.message.isNotEmpty)
                  Text(call.message,
                      style: context.text.caption),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
