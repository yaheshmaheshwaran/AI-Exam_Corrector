import 'package:flutter/material.dart';

import 'package:exam_corrector/app/app_theme.dart';
import 'package:exam_corrector/widgets/section_card.dart';

/// Step 2 — the mark scheme, typed, pasted, or loaded from a PDF.
///
/// The text is the authoritative marking criteria, so the hint spells out what
/// the AI needs in order to mark strictly against it.
class MarkSchemeInput extends StatelessWidget {
  const MarkSchemeInput({
    super.key,
    required this.controller,
    required this.isLoading,
    required this.onChanged,
    required this.onLoadFromPdf,
    required this.onClear,
  });

  final TextEditingController controller;
  final bool isLoading;
  final ValueChanged<String> onChanged;
  final VoidCallback? onLoadFromPdf;
  final VoidCallback? onClear;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);

    return SectionCard(
      title: '2. Mark scheme',
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          if (isLoading)
            const Padding(
              padding: EdgeInsets.only(right: 10),
              child: SizedBox(
                width: 14,
                height: 14,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ),
          OutlinedButton.icon(
            onPressed: onLoadFromPdf,
            icon: const Icon(Icons.upload_file_outlined, size: 16),
            label: const Text('Load from PDF…'),
          ),
          const SizedBox(width: 8),
          OutlinedButton(onPressed: onClear, child: const Text('Clear')),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Text(
            'Paste the mark scheme, or load it from a PDF. Include questions, '
            'expected answers, mark allocation, acceptable alternatives and '
            'partial-credit rules.',
            style: theme.textTheme.bodySmall
                ?.copyWith(color: AppTheme.textSecondary),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: controller,
            onChanged: onChanged,
            enabled: !isLoading,
            minLines: 5,
            maxLines: 5,
            textAlignVertical: TextAlignVertical.top,
            style: theme.textTheme.bodyMedium,
            decoration: const InputDecoration(
              hintText: 'Question 1 (5 marks)\n'
                  '  • States that … (1 mark)\n'
                  '  • Accept "…" or "…" (1 mark)',
              contentPadding: EdgeInsets.all(10),
            ),
          ),
        ],
      ),
    );
  }
}
