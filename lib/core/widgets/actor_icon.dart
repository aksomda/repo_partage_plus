import 'package:flutter/material.dart';

import 'package:repo_partage_plus/core/theme/app_theme.dart';

/// Icônes proposées à l'administrateur pour un acteur (nom stocké en base).
const actorIcons = <String, IconData>{
  'person': Icons.person_outline,
  'storefront': Icons.storefront_outlined,
  'restaurant': Icons.restaurant,
  'restaurant_menu': Icons.restaurant_menu,
  'bakery_dining': Icons.bakery_dining_outlined,
  'shopping_basket': Icons.shopping_basket_outlined,
  'groups': Icons.groups_outlined,
  'volunteer_activism': Icons.volunteer_activism_outlined,
  'admin_panel_settings': Icons.admin_panel_settings_outlined,
};

IconData actorIconData(String? name) =>
    actorIcons[name] ?? Icons.badge_outlined;

/// Libellés des droits (permission_role) d'un acteur.
const permissionLabels = <String, String>{
  'beneficiary': 'Récupère des produits',
  'donor': 'Publie des produits',
  'association': 'Association : récupère des produits pour d’autres',
  'admin': 'Administrateur',
};

/// Pastille ronde de l'acteur, verte pour qui récupère, orange pour qui publie.
class ActorAvatar extends StatelessWidget {
  const ActorAvatar({super.key, required this.actor, this.size = 48});

  final Map<String, dynamic> actor;
  final double size;

  @override
  Widget build(BuildContext context) {
    final publishes = actor['permission_role'] == 'donor';
    final admin = actor['permission_role'] == 'admin';
    final color = admin
        ? AppColors.text
        : publishes
        ? AppColors.accent
        : AppColors.primary;
    final background = admin
        ? AppColors.border
        : publishes
        ? AppColors.accentSoft
        : AppColors.primarySoft;

    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(color: background, shape: BoxShape.circle),
      child: Icon(
        actorIconData(actor['icon'] as String?),
        color: color,
        size: size * 0.5,
      ),
    );
  }
}
