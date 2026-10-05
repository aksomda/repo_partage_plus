import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'package:repo_partage_plus/core/router/app_routes.dart';
import 'package:repo_partage_plus/core/theme/app_theme.dart';
import 'package:repo_partage_plus/features/auth/data/auth_repository.dart';

/// Demande confirmation puis déconnecte : session et données locales
/// effacées. Prévient si des actions faites hors ligne ne sont pas encore
/// envoyées (elles seraient perdues).
Future<void> confirmLogout(BuildContext context, WidgetRef ref) async {
  final repository = ref.read(authRepositoryProvider);
  final unsent = repository.unsentActions;

  final confirmed = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('Se déconnecter ?'),
      content: Text(
        unsent == 0
            ? 'Les données enregistrées sur cet appareil seront effacées.'
            : '$unsent modification${unsent > 1 ? 's' : ''} pas encore '
                  'envoyée${unsent > 1 ? 's' : ''} (hors ligne) '
                  'ser${unsent > 1 ? 'ont' : 'a'} perdue${unsent > 1 ? 's' : ''}. '
                  'Reconnectez-vous à Internet pour les envoyer avant de '
                  'vous déconnecter.',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Annuler'),
        ),
        FilledButton(
          style: FilledButton.styleFrom(backgroundColor: AppColors.danger),
          onPressed: () => Navigator.of(context).pop(true),
          child: Text(
            unsent == 0 ? 'Se déconnecter' : 'Déconnecter quand même',
          ),
        ),
      ],
    ),
  );
  if (confirmed != true || !context.mounted) return;

  // Récupéré avant : le menu peut disparaître avec la session.
  final router = GoRouter.of(context);
  await repository.logout();
  router.go(AppRoutes.login);
}

/// Bas du menu : compte connecté et « Se déconnecter », ou « Se connecter ».
class AccountMenuFooter extends ConsumerWidget {
  const AccountMenuFooter({super.key, this.onDark = false});

  /// Sur fond vert (barre latérale de l'administration).
  final bool onDark;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final color = onDark ? Colors.white : AppColors.text;
    final muted = onDark ? Colors.white70 : AppColors.textMuted;

    if (!ref.watch(isLoggedInProvider)) {
      return Tooltip(
        message: 'Accéder à votre compte',
        waitDuration: const Duration(milliseconds: 400),
        child: ListTile(
          leading: Icon(Icons.login, color: onDark ? color : AppColors.primary),
          title: Text('Se connecter', style: TextStyle(color: color)),
          onTap: () => context.go(AppRoutes.login),
        ),
      );
    }

    final profile = ref.watch(profileProvider);
    final name = profile?['name'] as String?;
    final email = profile?['email'] as String?;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (name != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  name,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: color, fontWeight: FontWeight.w600),
                ),
                if (email != null)
                  Text(
                    email,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: muted, fontSize: 12),
                  ),
              ],
            ),
          ),
        Tooltip(
          message: 'Fermer la session et effacer les données de cet appareil',
          waitDuration: const Duration(milliseconds: 400),
          child: ListTile(
            leading: Icon(
              Icons.logout,
              color: onDark ? color : AppColors.danger,
            ),
            title: Text(
              'Se déconnecter',
              style: TextStyle(
                color: onDark ? color : AppColors.danger,
                fontWeight: FontWeight.w600,
              ),
            ),
            onTap: () => confirmLogout(context, ref),
          ),
        ),
      ],
    );
  }
}
