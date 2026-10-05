import 'package:flutter/material.dart';

import 'package:repo_partage_plus/core/offline/sync_controller.dart';
import 'package:repo_partage_plus/core/theme/app_theme.dart';
import 'package:repo_partage_plus/core/widgets/text_prompt_dialog.dart';
import 'package:repo_partage_plus/features/auth/presentation/widgets/auth_widgets.dart';

/// Message après une action d'administration : envoyée, mise en file (hors
/// ligne) ou refusée par le serveur. Renvoie true si l'action est prise en
/// compte (envoyée ou en file).
bool showAdminResult(
  BuildContext context,
  SubmitResult result, {
  required String sent,
}) {
  switch (result) {
    case Sent():
      showMessage(context, sent);
      return true;
    case Queued():
      showMessage(context, 'Hors ligne : sera envoyé au retour du réseau');
      return true;
    case Rejected(:final message):
      showMessage(context, message, error: true);
      return false;
  }
}

/// Demande un motif (refus, retrait…) ; null si l'administrateur annule.
Future<String?> askAdminReason(
  BuildContext context, {
  required String title,
  required String action,
  String hint = 'Motif communiqué à l’intéressé',
}) {
  return showTextPrompt(
    context,
    title: title,
    action: action,
    hint: hint,
    maxLines: 3,
    emptyMessage: 'Motif obligatoire',
    danger: true,
  );
}

/// Confirmation d'une suppression.
Future<bool> confirmAdminDelete(
  BuildContext context, {
  required String title,
  required String message,
}) async {
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(title),
      content: Text(message),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Annuler'),
        ),
        FilledButton(
          style: FilledButton.styleFrom(backgroundColor: AppColors.danger),
          onPressed: () => Navigator.of(context).pop(true),
          child: const Text('Supprimer'),
        ),
      ],
    ),
  );
  return confirmed == true;
}

/// Titre d'un formulaire en feuille modale.
class AdminSheetTitle extends StatelessWidget {
  const AdminSheetTitle(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 20),
      child: Text(
        text,
        style: Theme.of(
          context,
        ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700),
      ),
    );
  }
}

/// Ouvre un formulaire d'administration en feuille modale.
Future<T?> showAdminSheet<T>(BuildContext context, Widget form) {
  return showModalBottomSheet<T>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    backgroundColor: AppColors.surface,
    builder: (context) => Padding(
      padding: EdgeInsets.fromLTRB(
        24,
        0,
        24,
        24 + MediaQuery.viewInsetsOf(context).bottom,
      ),
      child: SingleChildScrollView(child: form),
    ),
  );
}
