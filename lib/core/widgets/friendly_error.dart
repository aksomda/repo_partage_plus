import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'package:repo_partage_plus/core/theme/app_theme.dart';

/// Remplace l'écran rouge de Flutter quand un widget échoue à s'afficher.
/// Autonome (pas de thème ni de MediaQuery requis) : il peut apparaître à la
/// place de tout l'écran comme d'un simple élément de liste.
class FriendlyErrorWidget extends StatelessWidget {
  const FriendlyErrorWidget({super.key, this.details});

  final FlutterErrorDetails? details;

  @override
  Widget build(BuildContext context) {
    return Directionality(
      textDirection: TextDirection.ltr,
      child: LayoutBuilder(
        builder: (context, constraints) {
          // Petit emplacement (carte, vignette) : une simple icône suffit.
          final compact =
              constraints.maxHeight < 220 || constraints.maxWidth < 220;
          return ColoredBox(
            color: AppColors.background,
            child: Center(child: compact ? _compact() : _full()),
          );
        },
      ),
    );
  }

  Widget _compact() => const Padding(
    padding: EdgeInsets.all(8),
    child: Icon(
      Icons.eco_outlined,
      color: AppColors.textMuted,
      size: 28,
      semanticLabel: 'Contenu momentanément indisponible',
    ),
  );

  Widget _full() {
    // En développement seulement : le détail technique reste lisible.
    final technical = kDebugMode ? details?.exceptionAsString() : null;
    return SingleChildScrollView(
      padding: const EdgeInsets.all(32),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 360),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 96,
              height: 96,
              decoration: const BoxDecoration(
                color: AppColors.primarySoft,
                shape: BoxShape.circle,
              ),
              child: const Icon(
                Icons.ramen_dining_outlined,
                size: 48,
                color: AppColors.primary,
              ),
            ),
            const SizedBox(height: 24),
            const Text(
              'Oups, petit souci en cuisine !',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: AppColors.text,
                fontSize: 20,
                fontWeight: FontWeight.w700,
                decoration: TextDecoration.none,
              ),
            ),
            const SizedBox(height: 12),
            const Text(
              'Cette page n’a pas pu s’afficher correctement. '
              'Revenez en arrière ou relancez l’application : '
              'vos données sont en sécurité.',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: AppColors.textMuted,
                fontSize: 15,
                height: 1.4,
                fontWeight: FontWeight.w400,
                decoration: TextDecoration.none,
              ),
            ),
            if (technical != null) ...[
              const SizedBox(height: 24),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: AppColors.accentSoft,
                  borderRadius: BorderRadius.circular(AppTheme.radius),
                ),
                child: Text(
                  technical,
                  style: const TextStyle(
                    color: AppColors.text,
                    fontSize: 11,
                    fontFamily: 'monospace',
                    fontWeight: FontWeight.w400,
                    decoration: TextDecoration.none,
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
