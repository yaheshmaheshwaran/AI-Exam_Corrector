import 'dart:io';

import 'package:flutter/material.dart';

import 'package:exam_corrector/app/app_theme.dart';
import 'package:exam_corrector/models/ocr/text_line.dart';

/// One recognised line: the image it was read from, and what was read.
///
/// The crop sits directly above the text so checking a line is a glance rather
/// than a hunt across the page. That pairing is the whole point of the review
/// screen — without it the teacher is being asked to trust a transcription they
/// have no way to verify.
class TranscriptLineTile extends StatefulWidget {
  const TranscriptLineTile({
    super.key,
    required this.line,
    required this.threshold,
    required this.onChanged,
    required this.onRevert,
  });

  final TextLine line;
  final double threshold;
  final ValueChanged<String> onChanged;
  final VoidCallback onRevert;

  @override
  State<TranscriptLineTile> createState() => _TranscriptLineTileState();
}

class _TranscriptLineTileState extends State<TranscriptLineTile> {
  late final TextEditingController _field;

  @override
  void initState() {
    super.initState();
    _field = TextEditingController(text: widget.line.text);
  }

  @override
  void didUpdateWidget(TranscriptLineTile oldWidget) {
    super.didUpdateWidget(oldWidget);

    // Only reseed when the change came from somewhere else — a revert, or the
    // list recycling this tile onto a different line. Reseeding on the
    // teacher's own keystrokes would fight the cursor.
    if (widget.line.text != _field.text) {
      _field.value = TextEditingValue(
        text: widget.line.text,
        selection: TextSelection.collapsed(offset: widget.line.text.length),
      );
    }
  }

  @override
  void dispose() {
    _field.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final TextLine line = widget.line;
    final bool uncertain = line.isUncertain(widget.threshold);

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: uncertain ? AppTheme.cautionFill : AppTheme.cardBackground,
        border: Border.all(
          color: uncertain ? const Color(0xFFE8CE6A) : AppTheme.stroke,
        ),
        borderRadius: BorderRadius.circular(AppTheme.controlRadius),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          _CropImage(path: line.cropPath),
          const SizedBox(height: 8),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Expanded(
                child: TextField(
                  controller: _field,
                  onChanged: widget.onChanged,
                  maxLines: null,
                  style: Theme.of(context).textTheme.bodyMedium,
                  decoration: const InputDecoration(
                    hintText: 'Nothing was recognised on this line',
                  ),
                ),
              ),
              const SizedBox(width: 8),
              _ConfidenceChip(line: line, threshold: widget.threshold),
              if (line.isEdited)
                Tooltip(
                  message: 'Restore what was recognised: "${line.ocrText}"',
                  child: IconButton(
                    onPressed: widget.onRevert,
                    icon: const Icon(Icons.undo, size: 16),
                    visualDensity: VisualDensity.compact,
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

/// The cropped strip of the page this line was read from.
class _CropImage extends StatelessWidget {
  const _CropImage({required this.path});

  final String path;

  @override
  Widget build(BuildContext context) {
    if (path.isEmpty) return const _MissingCrop();

    return ClipRRect(
      borderRadius: BorderRadius.circular(2),
      child: Container(
        color: Colors.white,
        constraints: const BoxConstraints(maxHeight: 64),
        width: double.infinity,
        child: Image.file(
          File(path),
          fit: BoxFit.contain,
          alignment: Alignment.centerLeft,
          filterQuality: FilterQuality.medium,
          // The crops live in a temporary directory that can be cleared while
          // the app is open; a missing one must not break the review.
          errorBuilder: (BuildContext context, Object error, StackTrace? trace) =>
              const _MissingCrop(),
        ),
      ),
    );
  }
}

class _MissingCrop extends StatelessWidget {
  const _MissingCrop();

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 28,
      alignment: Alignment.centerLeft,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      color: AppTheme.subtleBackground,
      child: const Text(
        'Line image unavailable',
        style: TextStyle(fontSize: 11, color: AppTheme.textDisabled),
      ),
    );
  }
}

/// How much the line's current text can be trusted, and who produced it.
class _ConfidenceChip extends StatelessWidget {
  const _ConfidenceChip({required this.line, required this.threshold});

  final TextLine line;
  final double threshold;

  @override
  Widget build(BuildContext context) {
    final (String label, Color colour, String tooltip) = _describe();

    return Tooltip(
      message: tooltip,
      child: Container(
        margin: const EdgeInsets.only(top: 4),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
          border: Border.all(color: colour.withValues(alpha: 0.45)),
          borderRadius: BorderRadius.circular(AppTheme.controlRadius),
        ),
        child: Text(
          label,
          style: TextStyle(fontSize: 11, color: colour),
        ),
      ),
    );
  }

  (String, Color, String) _describe() {
    switch (line.source) {
      case OcrSource.teacher:
        return (
          'Edited',
          AppTheme.success,
          'You corrected this line. It will be marked as you wrote it.',
        );
      case OcrSource.vision:
        return line.confidence >= threshold
            ? (
                'Confirmed',
                AppTheme.success,
                'Two recognisers read this line the same way.',
              )
            : (
                'Disputed',
                AppTheme.caution,
                'The two recognisers disagreed. The second reading is shown — '
                    'please check it.',
              );
      case OcrSource.trocr:
        final int percent = (line.confidence * 100).round();
        return line.confidence < threshold
            ? (
                'Unsure $percent%',
                AppTheme.caution,
                'The recogniser was not confident here. Check it against the '
                    'image above.',
              )
            : (
                '$percent%',
                AppTheme.textSecondary,
                'Recognition confidence.',
              );
    }
  }
}
