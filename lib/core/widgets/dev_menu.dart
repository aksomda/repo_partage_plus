import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import 'package:repo_partage_plus/core/router/app_routes.dart';
import 'package:repo_partage_plus/core/theme/app_theme.dart';
import 'package:repo_partage_plus/core/widgets/brand_logo.dart';
import 'package:repo_partage_plus/features/auth/presentation/widgets/logout_button.dart';

/// Tiroir listant tous les écrans, pour naviguer pendant le développement.
class DevMenu extends StatelessWidget {
  const DevMenu({super.key, required this.currentLocation});

  final String currentLocation;

  @override
  Widget build(BuildContext context) {
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
            child: const Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                BrandLogo(size: 24, onDark: true),
                SizedBox(height: 16),
                Text(
                  'Tous les écrans',
                  style: TextStyle(color: Colors.white70, fontSize: 13),
                ),
              ],
            ),
          ),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.symmetric(vertical: 8),
              children: [
                for (final group in MenuGroup.values) _group(context, group),
              ],
            ),
          ),
          const Divider(height: 1),
          const SafeArea(top: false, child: AccountMenuFooter()),
        ],
      ),
    );
  }

  /// Bloc thématique repliable ; ouvert s'il contient l'écran affiché.
  Widget _group(BuildContext context, MenuGroup group) {
    final entries = [
      for (final entry in allRouteEntries)
        if (entry.group == group) entry,
    ];
    final current = entries.any((entry) => entry.location == currentLocation);

    return ExpansionTile(
      initiallyExpanded: current,
      leading: Icon(group.icon, color: AppColors.primary),
      title: Text(
        group.title,
        style: const TextStyle(fontWeight: FontWeight.w700),
      ),
      shape: const Border(),
      collapsedShape: const Border(),
      childrenPadding: const EdgeInsets.only(left: 16),
      children: [
        for (final entry in entries)
          ListTile(
            dense: true,
            selected: entry.location == currentLocation,
            selectedColor: AppColors.primary,
            selectedTileColor: AppColors.primarySoft,
            title: Text(
              entry.title,
              style: const TextStyle(fontWeight: FontWeight.w500),
            ),
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
    );
  }
}
