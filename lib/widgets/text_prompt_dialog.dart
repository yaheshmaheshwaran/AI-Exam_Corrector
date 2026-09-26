import 'package:flutter/material.dart';

/// Asks for a line or two of text — a reason, a reply — and returns it, or
/// null when cancelled.
///
/// It owns its text field's controller, so the controller outlives the
/// dialog's closing animation rather than being thrown away under it.
class TextPromptDialog extends StatefulWidget {
  const TextPromptDialog({
    super.key,
    required this.title,
    required this.label,
    required this.confirm,
    this.intro,
    this.hint,
    this.fieldKey,
    this.confirmKey,
    this.preview,
  });

  /// Shown above the text field: the answer being asked about, for one.
  final Widget? preview;

  final String title;
  final String? intro;
  final String label;
  final String? hint;
  final String confirm;
  final Key? fieldKey;
  final Key? confirmKey;

  static Future<String?> show(
    BuildContext context, {
    required String title,
    required String label,
    required String confirm,
    String? intro,
    String? hint,
    Key? fieldKey,
    Key? confirmKey,
    Widget? preview,
  }) =>
      showDialog<String>(
        context: context,
        builder: (BuildContext context) => TextPromptDialog(
          title: title,
          intro: intro,
          label: label,
          hint: hint,
          confirm: confirm,
          fieldKey: fieldKey,
          confirmKey: confirmKey,
          preview: preview,
        ),
      );

  @override
  State<TextPromptDialog> createState() => _TextPromptDialogState();
}

class _TextPromptDialogState extends State<TextPromptDialog> {
  final TextEditingController _text = TextEditingController();

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: SizedBox(
        width: widget.preview == null ? 440 : 520,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            if (widget.intro != null) ...<Widget>[Text(widget.intro!), const SizedBox(height: 12)],
            if (widget.preview != null) ...<Widget>[widget.preview!, const SizedBox(height: 12)],
            TextField(
              key: widget.fieldKey,
              controller: _text,
              autofocus: true,
              minLines: 3,
              maxLines: 5,
              onChanged: (_) => setState(() {}),
              decoration: InputDecoration(labelText: widget.label, hintText: widget.hint),
            ),
          ],
        ),
      ),
      actions: <Widget>[
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
        FilledButton(
          key: widget.confirmKey,
          onPressed: _text.text.trim().isEmpty ? null : () => Navigator.of(context).pop(_text.text.trim()),
          child: Text(widget.confirm),
        ),
      ],
    );
  }
}
