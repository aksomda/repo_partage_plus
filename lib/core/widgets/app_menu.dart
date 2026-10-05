import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'package:repo_partage_plus/core/router/app_routes.dart';
import 'package:repo_partage_plus/core/theme/app_theme.dart';
import 'package:repo_partage_plus/core/widgets/brand_logo.dart';
import 'package:repo_partage_plus/features/auth/data/auth_repository.dart';
import 'package:repo_partage_plus/features/auth/presentation/widgets/logout_button.dart';

/// Entrée de navigation : libellé, description (affichée au survol ou par
/// appui long) et écran ouvert.
class MenuItem {
  const MenuItem(this.icon, this.title, this.description, this.location);

  final IconData icon;
  final String title;
  final String description;
  final String location;
}

/// Délai avant l'affichage d'une description au survol.
const menuTooltipDelay = Duration(milliseconds: 400);

/// Sans compte : découvrir, publier et réserver, ou créer un compte
/// (« Se connecter » est en bas du menu).
const guestMenuItems = [
  MenuItem(
    Icons.home_outlined,
    'Accueil',
    'Les offres disponibles autour de votre point de départ',
    AppRoutes.home,
  ),
  MenuItem(
    Icons.search,
    'Rechercher',
    'Trouver une offre par produit, catégorie ou distance',
    AppRoutes.search,
  ),
  MenuItem(
    Icons.map_outlined,
    'Carte des offres',
    'Les offres à proximité, sur la carte',
    AppRoutes.nearbyMap,
  ),
  MenuItem(
    Icons.add_circle_outline,
    'Publier une offre',
    'Donner ou vendre à prix réduit vos invendus et surplus',
    AppRoutes.createOffer,
  ),
  MenuItem(
    Icons.storefront_outlined,
    'Mes offres',
    'Vos publications faites sur cet appareil',
    AppRoutes.myOffers,
  ),
  MenuItem(
    Icons.event_available_outlined,
    'Mes réservations',
    'Vos réservations faites sur cet appareil et leur code de retrait',
    AppRoutes.myReservations,
  ),
  MenuItem(
    Icons.auto_awesome_outlined,
    'Recommandations',
    'Les offres qui vous correspondent, selon vos préférences',
    AppRoutes.recommendations,
  ),
  MenuItem(
    Icons.person_add_alt_outlined,
    'Créer un compte',
    'Suivre vos réservations, vos offres et votre impact sur tous vos appareils',
    AppRoutes.register,
  ),
];

/// Compte bénéficiaire, donateur ou association.
const userMenuItems = [
  MenuItem(
    Icons.home_outlined,
    'Accueil',
    'Les offres disponibles autour de votre point de départ',
    AppRoutes.home,
  ),
  MenuItem(
    Icons.search,
    'Rechercher',
    'Trouver une offre par produit, catégorie ou distance',
    AppRoutes.search,
  ),
  MenuItem(
    Icons.map_outlined,
    'Carte des offres',
    'Les offres à proximité, sur la carte',
    AppRoutes.nearbyMap,
  ),
  MenuItem(
    Icons.add_circle_outline,
    'Publier une offre',
    'Donner ou vendre à prix réduit vos invendus et surplus',
    AppRoutes.createOffer,
  ),
  MenuItem(
    Icons.storefront_outlined,
    'Mes offres',
    'Vos publications, leur risque de gaspillage et leurs réservations',
    AppRoutes.myOffers,
  ),
  MenuItem(
    Icons.event_available_outlined,
    'Mes réservations',
    'Vos réservations, celles reçues sur vos offres et les codes de retrait',
    AppRoutes.myReservations,
  ),
  MenuItem(
    Icons.auto_awesome_outlined,
    'Recommandations',
    'Les offres qui vous correspondent, selon vos préférences et votre historique',
    AppRoutes.recommendations,
  ),
  MenuItem(
    Icons.notifications_none,
    'Notifications',
    'Réservations, retraits, rappels et échanges avec l’équipe Partage+',
    AppRoutes.notifications,
  ),
  MenuItem(
    Icons.eco_outlined,
    'Mon impact',
    'Nourriture sauvée, CO₂ évité et personnes aidées grâce à vous',
    AppRoutes.impact,
  ),
  MenuItem(
    Icons.person_outline,
    'Profil',
    'Vos informations, votre mot de passe et vos préférences',
    AppRoutes.profile,
  ),
];

/// Administrateur : gestion de la plateforme (aussi la barre latérale).
const adminMenuItems = [
  MenuItem(
    Icons.dashboard_outlined,
    'Tableau de bord',
    'Activité de la plateforme, impact global et tâches à traiter',
    AppRoutes.adminDashboard,
  ),
  MenuItem(
    Icons.inventory_2_outlined,
    'Offres',
    'Offres en ligne : retirer une offre abusive',
    AppRoutes.adminOffers,
  ),
  MenuItem(
    Icons.people_outline,
    'Utilisateurs',
    'Comptes inscrits : ajouter, désactiver ou réactiver',
    AppRoutes.adminAccounts,
  ),
  MenuItem(
    Icons.event_note_outlined,
    'Réservations',
    'Toutes les réservations de la plateforme',
    AppRoutes.adminReservations,
  ),
  MenuItem(
    Icons.eco_outlined,
    'Impact',
    'Impact global, indicateurs sociaux et export CSV',
    AppRoutes.adminImpact,
  ),
  MenuItem(
    Icons.notifications_none,
    'Notifications',
    'Conversations avec les utilisateurs',
    AppRoutes.notifications,
  ),
  MenuItem(
    Icons.admin_panel_settings_outlined,
    'Administration',
    'Acteurs, associations, catégories et facteurs d’impact',
    AppRoutes.adminManage,
  ),
  MenuItem(
    Icons.settings_outlined,
    'Paramètres',
    'Quotas des publications et réservations sans compte',
    AppRoutes.adminSettings,
  ),
];

/// Entrées du menu selon la session et le rôle.
List<MenuItem> menuItemsFor({required bool loggedIn, String? role}) {
  if (!loggedIn) return guestMenuItems;
  return role == 'admin' ? adminMenuItems : userMenuItems;
}

/// Menu principal (tiroir) : seulement les écrans utiles à la personne,
/// selon qu'elle a un compte et selon son rôle. Une description s'affiche
/// au survol d'une entrée (appui long sur téléphone).
class AppMenu extends ConsumerWidget {
  const AppMenu({super.key, required this.currentLocation});

  final String currentLocation;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final items = menuItemsFor(
      loggedIn: ref.watch(isLoggedInProvider),
      role: ref.watch(profileProvider)?['role'] as String?,
    );
    final currentPath = Uri.parse(currentLocation).path;

    return Drawer(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            color: AppColors.primary,
            padding: EdgeInsets.fromLTRB(
              20,
              MediaQuery.paddingOf(context).top + 24,
              20,
              20,
            ),
            child: const BrandLogo(size: 24, onDark: true),
          ),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.symmetric(vertical: 8),
              children: [
                for (final item in items)
                  _MenuTile(item: item, selected: item.location == currentPath),
                // Outil de développement : absent de l'application publiée.
                if (kDebugMode) ...[
                  const Divider(),
                  _DebugScreens(currentPath: currentPath),
                ],
              ],
            ),
          ),
          const Divider(height: 1),
          const SafeArea(top: false, child: AccountMenuFooter()),
        ],
      ),
    );
  }
}

class _MenuTile extends StatelessWidget {
  const _MenuTile({required this.item, required this.selected});

  final MenuItem item;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: item.description,
      waitDuration: menuTooltipDelay,
      preferBelow: false,
      child: ListTile(
        leading: Icon(item.icon),
        title: Text(
          item.title,
          style: const TextStyle(fontWeight: FontWeight.w600),
        ),
        selected: selected,
        selectedColor: AppColors.primary,
        selectedTileColor: AppColors.primarySoft,
        onTap: () {
          Navigator.of(context).pop();
          if (!selected) context.go(item.location);
        },
      ),
    );
  }
}

/// Mode debug uniquement : tous les écrans déclarés, avec leur chemin,
/// pour naviguer pendant le développement.
class _DebugScreens extends StatelessWidget {
  const _DebugScreens({required this.currentPath});

  final String currentPath;

  @override
  Widget build(BuildContext context) {
    return ExpansionTile(
      leading: const Icon(Icons.bug_report_outlined),
      title: const Text('Développement : tous les écrans'),
      shape: const Border(),
      collapsedShape: const Border(),
      childrenPadding: const EdgeInsets.only(left: 16),
      children: [
        for (final group in MenuGroup.values)
          ExpansionTile(
            leading: Icon(group.icon, color: AppColors.primary),
            title: Text(
              group.title,
              style: const TextStyle(fontWeight: FontWeight.w700),
            ),
            shape: const Border(),
            collapsedShape: const Border(),
            children: [
              for (final entry in allRouteEntries)
                if (entry.group == group)
                  ListTile(
                    dense: true,
                    selected: entry.location == currentPath,
                    title: Text(entry.title),
                    subtitle: Text(
                      entry.location,
                      style: const TextStyle(color: AppColors.textMuted),
                    ),
                    onTap: () {
                      Navigator.of(context).pop();
                      context.go(entry.location);
                    },
                  ),
            ],
          ),
      ],
    );
  }
}
