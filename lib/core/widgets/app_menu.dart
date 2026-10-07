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

/// Rubrique du menu : un titre (facultatif) et ses entrées.
class MenuSection {
  const MenuSection(this.title, this.items);

  final String? title;
  final List<MenuItem> items;
}

/// Délai avant l'affichage d'une description au survol.
const menuTooltipDelay = Duration(milliseconds: 400);

// Entrées communes, reprises dans les menus des acteurs.
const _home = MenuItem(
  Icons.home_outlined,
  'Accueil',
  'Les offres disponibles autour de votre point de départ',
  AppRoutes.home,
);
const _search = MenuItem(
  Icons.search,
  'Rechercher',
  'Trouver une offre par produit, catégorie ou distance',
  AppRoutes.search,
);
const _map = MenuItem(
  Icons.map_outlined,
  'Carte des offres',
  'Les offres à proximité, sur la carte',
  AppRoutes.nearbyMap,
);
const _recommendations = MenuItem(
  Icons.auto_awesome_outlined,
  'Recommandations',
  'Les offres qui vous correspondent, selon vos préférences et votre historique',
  AppRoutes.recommendations,
);
const _myOffers = MenuItem(
  Icons.storefront_outlined,
  'Mes offres',
  'Vos publications, leur risque de gaspillage et leurs réservations',
  AppRoutes.myOffers,
);
const _notifications = MenuItem(
  Icons.notifications_none,
  'Notifications',
  'Réservations, retraits, rappels et échanges avec l’équipe Partage+',
  AppRoutes.notifications,
);
const _profile = MenuItem(
  Icons.person_outline,
  'Profil',
  'Vos informations, votre mot de passe et vos préférences',
  AppRoutes.profile,
);

/// Sans compte : découvrir, publier et réserver, ou créer un compte
/// (« Se connecter » est en bas du menu).
const guestMenu = [
  MenuSection('Découvrir', [
    _home,
    _search,
    _map,
    MenuItem(
      Icons.auto_awesome_outlined,
      'Recommandations',
      'Les offres qui vous correspondent, selon vos préférences',
      AppRoutes.recommendations,
    ),
  ]),
  MenuSection('Partager', [
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
  ]),
  MenuSection('Compte', [
    MenuItem(
      Icons.person_add_alt_outlined,
      'Créer un compte',
      'Suivre vos réservations, vos offres et votre impact sur tous vos appareils',
      AppRoutes.register,
    ),
  ]),
];

/// Particulier : trouver des produits près de chez soi et les retirer.
const particulierMenu = [
  MenuSection('Trouver', [_home, _search, _map, _recommendations]),
  MenuSection('Mes retraits', [
    MenuItem(
      Icons.event_available_outlined,
      'Mes réservations',
      'Vos réservations et leur code de retrait',
      AppRoutes.myReservations,
    ),
  ]),
  MenuSection('Partager aussi', [
    MenuItem(
      Icons.add_circle_outline,
      'Donner un surplus',
      'Un surplus à la maison ? Proposez-le plutôt que de le jeter',
      AppRoutes.createOffer,
    ),
    _myOffers,
  ]),
  MenuSection('Mon compte', [
    _notifications,
    MenuItem(
      Icons.eco_outlined,
      'Mon impact',
      'Nourriture sauvée et CO₂ évité grâce à vos retraits',
      AppRoutes.impact,
    ),
    _profile,
  ]),
];

/// Commerçant : publier ses invendus et gérer les commandes reçues.
const commercantMenu = [
  MenuSection('Mon commerce', [
    _home,
    MenuItem(
      Icons.add_circle_outline,
      'Publier des invendus',
      'Invendus et surplus du magasin, à donner ou à prix réduit',
      AppRoutes.createOffer,
    ),
    _myOffers,
    MenuItem(
      Icons.receipt_long_outlined,
      'Commandes & réservations',
      'Réservations reçues sur vos offres, confirmation et validation des retraits',
      AppRoutes.myReservations,
    ),
  ]),
  MenuSection('Suivi', [
    _notifications,
    MenuItem(
      Icons.eco_outlined,
      'Mon impact',
      'Produits sauvés, CO₂ évité et personnes aidées par votre commerce',
      AppRoutes.impact,
    ),
  ]),
  MenuSection('Explorer', [_map, _search]),
  MenuSection('Mon compte', [_profile]),
];

/// Restaurateur : publier les plats et invendus du service.
const restaurateurMenu = [
  MenuSection('Mon restaurant', [
    _home,
    MenuItem(
      Icons.add_circle_outline,
      'Publier des plats',
      'Plats et invendus du service, avec un créneau de retrait',
      AppRoutes.createOffer,
    ),
    _myOffers,
    MenuItem(
      Icons.receipt_long_outlined,
      'Commandes & réservations',
      'Réservations reçues sur vos plats, confirmation et validation des retraits',
      AppRoutes.myReservations,
    ),
  ]),
  MenuSection('Suivi', [
    _notifications,
    MenuItem(
      Icons.eco_outlined,
      'Mon impact',
      'Repas sauvés, CO₂ évité et personnes aidées par votre restaurant',
      AppRoutes.impact,
    ),
  ]),
  MenuSection('Explorer', [_map, _search]),
  MenuSection('Mon compte', [_profile]),
];

/// Association : collecter pour les personnes aidées et redistribuer.
const associationMenu = [
  MenuSection('Collecter', [
    _home,
    _map,
    _search,
    _recommendations,
    MenuItem(
      Icons.event_available_outlined,
      'Mes collectes',
      'Produits réservés pour les personnes aidées et codes de retrait',
      AppRoutes.myReservations,
    ),
  ]),
  MenuSection('Redistribuer', [
    MenuItem(
      Icons.add_circle_outline,
      'Publier une offre',
      'Redonner un surplus reçu à d’autres associations ou particuliers',
      AppRoutes.createOffer,
    ),
    _myOffers,
  ]),
  MenuSection('Suivi', [
    _notifications,
    MenuItem(
      Icons.eco_outlined,
      'Impact de l’association',
      'Repas distribués, personnes aidées et CO₂ évité',
      AppRoutes.impact,
    ),
  ]),
  MenuSection('Mon compte', [
    MenuItem(
      Icons.person_outline,
      'Profil',
      'Informations de l’association, mot de passe et préférences',
      AppRoutes.profile,
    ),
  ]),
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

const adminMenu = [MenuSection(null, adminMenuItems)];

/// Menu selon la session, les droits ([role]) et l'acteur ([actorCode]).
/// Un acteur créé par l'administrateur prend le menu de ses droits.
List<MenuSection> menuFor({
  required bool loggedIn,
  String? role,
  String? actorCode,
}) {
  if (!loggedIn) return guestMenu;
  if (role == 'admin') return adminMenu;
  return switch (actorCode) {
    'particulier' => particulierMenu,
    'commercant' => commercantMenu,
    'restaurateur' => restaurateurMenu,
    'association' => associationMenu,
    _ => switch (role) {
      'donor' => commercantMenu,
      'association' => associationMenu,
      _ => particulierMenu,
    },
  };
}

/// Couleur du menu selon la session, les droits et l'acteur : mêmes règles
/// que [menuFor].
Color menuColorFor({required bool loggedIn, String? role, String? actorCode}) {
  if (!loggedIn) return MenuColors.guest;
  if (role == 'admin') return MenuColors.admin;
  return switch (actorCode) {
    'particulier' => MenuColors.particulier,
    'commercant' => MenuColors.commercant,
    'restaurateur' => MenuColors.restaurateur,
    'association' => MenuColors.association,
    _ => switch (role) {
      'donor' => MenuColors.commercant,
      'association' => MenuColors.association,
      _ => MenuColors.particulier,
    },
  };
}

/// Menu principal (tiroir), sur la couleur de l'acteur ([menuColorFor]) :
/// seulement les écrans utiles à la personne, selon son compte et son
/// acteur. Une description s'affiche au survol d'une entrée (appui long sur
/// téléphone).
class AppMenu extends ConsumerWidget {
  const AppMenu({super.key, required this.currentLocation});

  final String currentLocation;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final profile = ref.watch(profileProvider);
    final loggedIn = ref.watch(isLoggedInProvider);
    final role = profile?['role'] as String?;
    final actorCode = profile?['actor_code'] as String?;
    final sections = menuFor(
      loggedIn: loggedIn,
      role: role,
      actorCode: actorCode,
    );

    return Drawer(
      backgroundColor: menuColorFor(
        loggedIn: loggedIn,
        role: role,
        actorCode: actorCode,
      ),
      child: SafeArea(
        child: MenuPanel(
          sections: sections,
          current: Uri.parse(currentLocation).path,
          inDrawer: true,
        ),
      ),
    );
  }
}

/// Panneau de navigation vert : logo, rubriques, puis compte connecté et
/// « Se déconnecter ». Commun au tiroir et à la barre latérale de
/// l'administration.
class MenuPanel extends StatelessWidget {
  const MenuPanel({
    super.key,
    required this.sections,
    required this.current,
    this.inDrawer = false,
  });

  final List<MenuSection> sections;

  /// Chemin de l'écran affiché, mis en évidence.
  final String current;

  /// Dans un tiroir : il se referme avant d'ouvrir l'écran choisi.
  final bool inDrawer;

  @override
  Widget build(BuildContext context) {
    return Padding(
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
                for (final section in sections) ...[
                  if (section.title != null) _SectionTitle(section.title!),
                  for (final item in section.items)
                    _NavItem(
                      item: item,
                      selected: item.location == current,
                      onTap: () {
                        if (inDrawer) Navigator.of(context).pop();
                        context.go(item.location);
                      },
                    ),
                ],
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

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.title);

  final String title;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 14, 12, 6),
      child: Text(
        title.toUpperCase(),
        style: const TextStyle(
          color: Colors.white70,
          fontSize: 11,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.8,
        ),
      ),
    );
  }
}

class _NavItem extends StatelessWidget {
  const _NavItem({
    required this.item,
    required this.selected,
    required this.onTap,
  });

  final MenuItem item;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: item.description,
      waitDuration: menuTooltipDelay,
      child: Padding(
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
                  Icon(item.icon, size: 20, color: Colors.white),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      item.title,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: Colors.white,
                        fontWeight: selected
                            ? FontWeight.w700
                            : FontWeight.w500,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Bouton de gauche d'un écran à menu : retour quand l'écran a été ouvert
/// par-dessus un autre, sinon (null) le bouton du tiroir.
Widget? backOrMenuButton(BuildContext context) =>
    Navigator.of(context).canPop() ? const BackButton() : null;
