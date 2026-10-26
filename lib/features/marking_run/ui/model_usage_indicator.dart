import 'dart:async';

import 'package:flutter/material.dart';

import 'package:exam_corrector/shared/ui/app_dialog.dart';

import 'package:exam_corrector/app/app_colors.dart';
import 'package:exam_corrector/app/app_text.dart';
import 'package:exam_corrector/app/app_theme.dart';
import 'package:exam_corrector/ai/ai_settings.dart';
import 'package:exam_corrector/ai/model_roles.dart';
import 'package:exam_corrector/app/observable_listenable.dart';
import 'package:exam_corrector/core/utils/duration_format.dart';
import 'package:exam_corrector/ai/usage.dart';

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

  static ModelStatus of(AiSettings ai, UsageMonitor usage) {
    final DateTime now = usage.now;
    final List<String> chain = ai.roles.chain(ModelRole.marker);
    if (!ai.hasModelAccess) {
      return const ModelStatus(ModelState.noKey, 'AI not set up', AiSettings.notReadyMessage);
    }
    final ModelCall? call = usage.active;
    if (call != null && call.status == CallStatus.waiting && call.retryAt != null) {
      final int seconds = call.retryAt!.difference(now).inSeconds.clamp(0, 999);
      final bool ours = ai.providers.of(call.model)?.selfHosted ?? false;
      return ModelStatus(
        ModelState.waiting,
        ours ? 'Retrying in ${seconds}s' : 'Rate limited · retrying in ${seconds}s',
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
        'Out of allowance · back at ${clock(reset)}',
        'Every marking model is out of its allowance until ${clock(reset)}. Marking '
            'waits for them, and a class being marked carries on by itself then. '
            'Add another marking model in Settings to carry on sooner.',
      );
    }
    if (out.isNotEmpty) {
      final String using = chain.firstWhere((String m) => !out.contains(m));
      return ModelStatus(
        ModelState.degraded,
        '${shortName(out.first)} out of allowance · using ${shortName(using)}',
        '${out.join(', ')} ${out.length == 1 ? 'is' : 'are'} out of its allowance for now, so '
            '$using marks instead. Marks by a backup model are flagged for your review.',
      );
    }
    final int requests = usage.requestsToday;
    return ModelStatus(
      ModelState.idle,
      '${chain.isEmpty ? 'No model' : shortName(chain.first)} · $requests request${requests == 1 ? '' : 's'} today',
      '${chain.isEmpty ? 'The AI' : chain.first} is idle. $requests request${requests == 1 ? ' has' : 's have'} '
          'been sent today.',
    );
  }

  static String _duration(int seconds) => formatElapsed(Duration(seconds: seconds));

  /// A model's name as the bar shows it: without the provider before it or
  /// the build details after it — `hf/Qwen/Qwen3-VL-30B-A3B-Instruct` is
  /// `Qwen3-VL-30B`, `ollama/qwen3-vl:8b-instruct` is `qwen3-vl:8b`. The full
  /// name stays in the details.
  static String shortName(String model) {
    String name = model.substring(model.lastIndexOf('/') + 1);
    final RegExp build = RegExp(r'-(instruct|thinking|chat|awq|gptq|fp8|int4|int8|a\d+b)$', caseSensitive: false);
    while (build.hasMatch(name)) {
      name = name.replaceFirst(build, '');
    }
    return name.isEmpty ? model : name;
  }

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
  const ModelUsageIndicator({super.key, required this.ai, required this.usage});

  final AiSettings ai;
  final UsageMonitor usage;

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
    final ModelStatus status = ModelStatus.of(widget.ai, widget.usage);
    final AppColors c = context.colors;
    // A raised white pill, like the app's other buttons; tinted only when
    // the AI needs the teacher.
    final Tone? alert = switch (status.state) {
      ModelState.noKey || ModelState.degraded || ModelState.waiting => c.tone(ToneKind.warning),
      ModelState.exhausted => c.tone(ToneKind.danger),
      ModelState.working || ModelState.idle => null,
    };
    final Color colour = alert?.foreground ?? c.primary;
    final IconData icon = switch (status.state) {
      ModelState.noKey => Icons.key_off_outlined,
      ModelState.waiting => Icons.hourglass_top,
      ModelState.exhausted => Icons.block,
      ModelState.degraded => Icons.swap_horiz,
      ModelState.working || ModelState.idle => Icons.auto_awesome_outlined,
    };
    // What it is in full weight; the rest — a count, a time — quieter.
    final int split = status.short.indexOf(' · ');
    final String lead = split < 0 ? status.short : status.short.substring(0, split);
    final String rest = split < 0 ? '' : status.short.substring(split);
    final BorderRadius corners = BorderRadius.circular(AppTheme.pillRadius);

    return Tooltip(
      message: '${status.long}\nClick for model usage.',
      child: DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: corners,
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: alert == null
                ? const <Color>[Color(0xFFFFFFFF), Color(0xFFF3F1EE)]
                : <Color>[Color.alphaBlend(alert.fill.withValues(alpha: 0.45), Colors.white), alert.fill],
          ),
          border: Border.all(color: alert?.border ?? c.text.withValues(alpha: 0.15), width: 0.5),
          boxShadow: const <BoxShadow>[
            BoxShadow(color: Color(0x1A3E2F23), offset: Offset(0, 1.5)),
            BoxShadow(color: Color(0x12171717), blurRadius: 8, offset: Offset(0, 3)),
          ],
        ),
        child: Material(
          type: MaterialType.transparency,
          child: InkWell(
            key: const Key('model-usage'),
            borderRadius: corners,
            hoverColor: Colors.white.withValues(alpha: 0.5),
            onTap: () => ModelUsageDialog.show(context, widget.ai, widget.usage),
            child: SizedBox(
              height: 22,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 10),
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
                      child: Text.rich(
                        TextSpan(
                          text: lead,
                          children: <InlineSpan>[
                            if (rest.isNotEmpty)
                              TextSpan(
                                text: rest,
                                style: TextStyle(fontWeight: FontWeight.w500, color: alert?.foreground ?? c.textFaint),
                              ),
                          ],
                        ),
                        key: const Key('model-usage-text'),
                        overflow: TextOverflow.ellipsis,
                        maxLines: 1,
                        style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w600, color: colour, height: 1.2),
                      ),
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

/// Today's use of each model, their limits, and the latest requests.
class ModelUsageDialog extends StatelessWidget {
  const ModelUsageDialog({super.key, required this.ai, required this.usage});

  final AiSettings ai;
  final UsageMonitor usage;

  static Future<void> show(BuildContext context, AiSettings ai, UsageMonitor usage) =>
      showAppDialog<void>(
        context: context,
        builder: (BuildContext context) => ModelUsageDialog(ai: ai, usage: usage),
      );

  /// What [model] does here, for the table.
  String _role(String model) => <String>[
        for (final ModelRole role in ModelRole.values)
          if (ai.roles.chain(role).contains(model))
            '${role.label}${ai.roles.chain(role).first == model ? '' : ', backup'}',
      ].join('; ');

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return ListenableBuilder(
      listenable: usage.listenable,
      builder: (BuildContext context, _) {
        final ModelStatus status = ModelStatus.of(ai, usage);
        final Map<String, DayUsage> today = usage.today;
        final List<String> models = <String>{
          for (final ModelRole role in ModelRole.values) ...ai.roles.chain(role),
          ...today.keys,
        }.toList();
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
                  "Gemini's free allowances are counted per Google day, which resets at midnight Pacific "
                  'time — ${ModelStatus.clock(UsageMonitor.nextQuotaReset(usage.now))} your time. NVIDIA\'s free '
                  'models are shared and may not answer at busy times. Your own servers have no limit.',
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
                            '$model${_role(model).isEmpty ? '' : '  (${_role(model)})'}',
                            style: cell,
                          ),
                        ),
                        Text(
                          '${today[model]?.requests ?? 0}'
                          '${today[model]?.limit == null ? '' : ' / ${today[model]!.limit}'}',
                          key: ValueKey<String>('usage-requests-$model'),
                          style: cell,
                        ),
                        Text('${today[model]?.failures ?? 0}', style: cell),
                        Text('${today[model]?.rateLimited ?? 0}', style: cell),
                        Text(
                          switch (usage.exhaustedUntil(model)) {
                            final DateTime until => 'Out of allowance until ${ModelStatus.clock(until)}',
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
      CallStatus.running => (Icons.more_horiz, context.colors.primary, 'working'),
      CallStatus.waiting => (Icons.hourglass_top, context.colors.warning, 'waiting out a rate limit'),
      CallStatus.succeeded => (Icons.check_circle_outline, context.colors.success, 'done'),
      CallStatus.failed => (Icons.error_outline, context.colors.danger, 'failed'),
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
