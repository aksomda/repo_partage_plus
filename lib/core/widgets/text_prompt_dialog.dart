import 'package:flutter/material.dart';

import 'package:repo_partage_plus/core/theme/app_theme.dart';

/// Demande un texte (motif, nom…) ; null si l'utilisateur annule. Le
/// dialogue garde son contrôleur jusqu'à la fin de l'animation de fermeture.
Future<String?> showTextPrompt(
  BuildContext context, {
  required String title,
  required String action,
  String? hint,
  String initial = '',
  int maxLength = 255,
  int maxLines = 1,
  String emptyMessage = 'Champ obligatoire',
  bool danger = false,
}) {
  return showDialog<String>(
    context: context,
    builder: (context) => _TextPromptDialog(
      title: title,
      action: action,
      hint: hint,
      initial: initial,
      maxLength: maxLength,
      maxLines: maxLines,
      emptyMessage: emptyMessage,
      danger: danger,
    ),
  );
}

class _TextPromptDialog extends StatefulWidget {
  const _TextPromptDialog({
    required this.title,
    required this.action,
    required this.hint,
    required this.initial,
    required this.maxLength,
    required this.maxLines,
    required this.emptyMessage,
    required this.danger,
  });

  final String title;
  final String action;
  final String? hint;
  final String initial;
  final int maxLength;
  final int maxLines;
  final String emptyMessage;
  final bool danger;

  @override
  State<_TextPromptDialog> createState() => _TextPromptDialogState();
}

class _TextPromptDialogState extends State<_TextPromptDialog> {
  final _form = GlobalKey<FormState>();
  late final _controller = TextEditingController(text: widget.initial);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    if (_form.currentState!.validate()) {
      Navigator.of(context).pop(_controller.text.trim());
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: Form(
        key: _form,
        child: TextFormField(
          controller: _controller,
          autofocus: true,
          maxLength: widget.maxLength,
          maxLines: widget.maxLines,
          minLines: 1,
          textCapitalization: TextCapitalization.sentences,
          decoration: InputDecoration(hintText: widget.hint),
          validator: (value) =>
              (value?.trim().isEmpty ?? true) ? widget.emptyMessage : null,
          onFieldSubmitted: widget.maxLines == 1 ? (_) => _submit() : null,
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Annuler'),
        ),
        FilledButton(
          style: widget.danger
              ? FilledButton.styleFrom(backgroundColor: AppColors.danger)
              : null,
          onPressed: _submit,
          child: Text(widget.action),
        ),
      ],
    );
  }
}
