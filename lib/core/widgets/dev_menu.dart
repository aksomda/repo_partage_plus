import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import 'package:repo_partage_plus/core/router/app_routes.dart';
import 'package:repo_partage_plus/core/theme/app_theme.dart';
import 'package:repo_partage_plus/core/widgets/brand_logo.dart';

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
                for (final entry in allRouteEntries)
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
            ),
          ),
        ],
      ),
    );
  }
}
