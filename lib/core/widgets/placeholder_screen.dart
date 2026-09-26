import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import 'package:repo_partage_plus/core/router/app_routes.dart';
import 'package:repo_partage_plus/core/theme/app_theme.dart';
import 'package:repo_partage_plus/core/widgets/brand_logo.dart';

/// Écran temporaire affiché tant qu'une feature n'est pas implémentée.
///
/// Le tiroir liste tous les écrans pour pouvoir naviguer pendant le dev.
class PlaceholderScreen extends StatelessWidget {
  const PlaceholderScreen({super.key, required this.title, this.details});

  final String title;
  final String? details;

  @override
  Widget build(BuildContext context) {
    final location = GoRouterState.of(context).uri.toString();
    final textTheme = Theme.of(context).textTheme;

    return Scaffold(
      appBar: AppBar(title: Text(title)),
      drawer: _DevMenu(currentLocation: location),
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: Card(
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 24,
                  vertical: 32,
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 72,
                      height: 72,
                      decoration: const BoxDecoration(
                        color: AppColors.primarySoft,
                        shape: BoxShape.circle,
                      ),
                      child: const Icon(
                        Icons.eco_outlined,
                        size: 36,
                        color: AppColors.primary,
                      ),
                    ),
                    const SizedBox(height: 20),
                    Text(
                      title,
                      textAlign: TextAlign.center,
                      style: textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 12),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 4,
                      ),
                      decoration: const ShapeDecoration(
                        color: AppColors.accentSoft,
                        shape: StadiumBorder(),
                      ),
                      child: Text(
                        'Bientôt disponible',
                        style: textTheme.labelMedium?.copyWith(
                          color: AppColors.accent,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),
                    Text(
                      location,
                      style: textTheme.bodySmall?.copyWith(
                        color: AppColors.textMuted,
                        fontFamily: 'monospace',
                      ),
                    ),
                    if (details != null) ...[
                      const SizedBox(height: 8),
                      Text(
                        details!,
                        textAlign: TextAlign.center,
                        style: textTheme.bodyMedium?.copyWith(
                          color: AppColors.textMuted,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _DevMenu extends StatelessWidget {
  const _DevMenu({required this.currentLocation});

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
