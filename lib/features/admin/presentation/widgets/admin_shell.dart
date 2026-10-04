import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'package:repo_partage_plus/core/offline/sync_controller.dart';
import 'package:repo_partage_plus/core/offline/sync_service.dart';
import 'package:repo_partage_plus/core/router/app_routes.dart';
import 'package:repo_partage_plus/core/theme/app_theme.dart';
import 'package:repo_partage_plus/core/widgets/brand_logo.dart';
import 'package:repo_partage_plus/core/widgets/dev_menu.dart';
import 'package:repo_partage_plus/features/auth/presentation/widgets/auth_widgets.dart';
import 'package:repo_partage_plus/features/auth/presentation/widgets/logout_button.dart';

/// Largeur à partir de laquelle on affiche la barre latérale et les tableaux.
const adminWideLayout = 900.0;

/// Cadre commun des écrans d'administration : barre latérale verte sur grand
/// écran (comme la maquette), menu tiroir sur téléphone.
class AdminShell extends StatelessWidget {
  const AdminShell({
    super.key,
    required this.title,
    required this.current,
    required this.builder,
    this.actions = const [],
  });

  final String title;

  /// Route de l'écran, mise en évidence dans la barre latérale.
  final String current;

  /// Contenu ; `wide` : grand écran (tableau plutôt que cartes).
  final Widget Function(BuildContext context, bool wide) builder;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    final location = GoRouterState.of(context).uri.toString();
    return LayoutBuilder(
      builder: (context, constraints) {
        final wide = constraints.maxWidth >= adminWideLayout;
        final body = builder(context, wide);
        return Scaffold(
          appBar: AppBar(
            title: Text(title),
            automaticallyImplyLeading: !wide,
            actions: actions,
          ),
          drawer: wide ? null : DevMenu(currentLocation: location),
          body: wide
              ? Row(
                  children: [
                    AdminSideNav(current: current),
                    const VerticalDivider(width: 1),
                    Expanded(child: body),
                  ],
                )
              : body,
        );
      },
    );
  }
}

class AdminSideNav extends StatelessWidget {
  const AdminSideNav({super.key, required this.current});

  final String current;

  static const items = [
    (Icons.dashboard_outlined, 'Tableau de bord', AppRoutes.adminDashboard),
    (Icons.inventory_2_outlined, 'Offres', AppRoutes.adminOffers),
    (Icons.people_outline, 'Utilisateurs', AppRoutes.adminAccounts),
    (Icons.event_note_outlined, 'Réservations', AppRoutes.adminReservations),
    (Icons.eco_outlined, 'Impact', AppRoutes.adminImpact),
    (Icons.notifications_none, 'Notifications', AppRoutes.notifications),
    (
      Icons.admin_panel_settings_outlined,
      'Administration',
      AppRoutes.adminManage,
    ),
    (Icons.settings_outlined, 'Paramètres', AppRoutes.adminSettings),
  ];

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 220,
      color: AppColors.primary,
      padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: ListView(
              children: [
                const Padding(
                  padding: EdgeInsets.fromLTRB(8, 0, 8, 20),
                  child: BrandLogo(size: 24, onDark: true, showTagline: false),
                ),
                for (final (icon, label, route) in items)
                  _NavItem(
                    icon: icon,
                    label: label,
                    selected: route == current,
                    onTap: () => context.go(route),
                  ),
              ],
            ),
          ),
          const Divider(color: Colors.white24),
          // Material : effet au toucher visible sur le fond vert.
          const Material(
            type: MaterialType.transparency,
            child: AccountMenuFooter(onDark: true),
          ),
        ],
      ),
    );
  }
}

class _NavItem extends StatelessWidget {
  const _NavItem({
    required this.icon,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 2),
      child: Material(
        color: selected
            ? Colors.white.withValues(alpha: 0.16)
            : Colors.transparent,
        borderRadius: BorderRadius.circular(8),
        child: InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: selected ? null : onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            child: Row(
              children: [
                Icon(icon, size: 20, color: Colors.white),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    label,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: Colors.white,
                      fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Actualise les données d'administration (synchronisation complète).
/// Hors ligne ou serveur indisponible : la copie locale reste affichée.
Future<void> refreshAdminData(BuildContext context, WidgetRef ref) async {
  if (!(ref.read(onlineProvider).value ?? false)) {
    showMessage(
      context,
      'Hors ligne : dernière copie enregistrée sur l’appareil',
      error: true,
    );
    return;
  }
  final report = await ref.read(syncControllerProvider.notifier).syncNow();
  if (!context.mounted) return;
  if (report.outcome == SyncOutcome.done) {
    showMessage(context, 'Données à jour');
  } else {
    showMessage(
      context,
      'Serveur indisponible : dernière copie enregistrée sur l’appareil',
      error: true,
    );
  }
}

/// Bouton « Actualiser » de la barre du haut.
class AdminSyncButton extends ConsumerWidget {
  const AdminSyncButton({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final syncing = ref.watch(syncControllerProvider.select((s) => s.syncing));
    return IconButton(
      tooltip: 'Actualiser',
      onPressed: syncing ? null : () => refreshAdminData(context, ref),
      icon: syncing
          ? const SizedBox.square(
              dimension: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : const Icon(Icons.sync),
    );
  }
}

/// Pastille de statut (Actif, Désactivé, Confirmée…).
class AdminBadge extends StatelessWidget {
  const AdminBadge(this.label, this.background, this.foreground, {super.key});

  final String label;
  final Color background;
  final Color foreground;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: ShapeDecoration(
        color: background,
        shape: const StadiumBorder(),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: foreground,
          fontSize: 11,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

/// Message centré (liste vide, pas encore de copie locale) ; ListView pour
/// que « tirer pour actualiser » fonctionne aussi.
class AdminEmptyMessage extends StatelessWidget {
  const AdminEmptyMessage({super.key, required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(32),
      children: [
        const SizedBox(height: 48),
        Icon(icon, size: 48, color: AppColors.textMuted),
        const SizedBox(height: 12),
        Text(
          text,
          textAlign: TextAlign.center,
          style: const TextStyle(color: AppColors.textMuted),
        ),
      ],
    );
  }
}

/// Date locale au format jj/mm/aaaa (hh:mm si [time]) ; « — » si absente.
String formatAdminDate(Object? value, {bool time = false}) {
  final date = DateTime.tryParse('${value ?? ''}')?.toLocal();
  if (date == null) return '—';
  String two(int n) => n.toString().padLeft(2, '0');
  final day = '${two(date.day)}/${two(date.month)}/${date.year}';
  return time ? '$day ${two(date.hour)}:${two(date.minute)}' : day;
}

/// Texte sans accents ni majuscules, pour les recherches locales.
String foldText(String value) {
  const from = 'àâäáãçéèêëíìîïñóòôöõúùûüÿ';
  const to = 'aaaaaceeeeiiiinooooouuuuy';
  final buffer = StringBuffer();
  for (final char in value.toLowerCase().trim().split('')) {
    final index = from.indexOf(char);
    buffer.write(index < 0 ? char : to[index]);
  }
  return buffer.toString();
}

/// true si chaque mot de [query] apparaît dans [text] (accents ignorés).
bool matchesSearch(String text, String query) {
  final words = foldText(query).split(' ').where((word) => word.isNotEmpty);
  final folded = foldText(text);
  return words.every(folded.contains);
}
