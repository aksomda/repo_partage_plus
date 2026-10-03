import 'package:flutter/material.dart';

import 'package:repo_partage_plus/core/theme/app_theme.dart';

/// Logo « Partage+ » : emblème (image) suivi du nom et du slogan optionnel.
///
/// [onDark] pour l'afficher sur fond vert (barre latérale admin, bandeaux).
/// [BrandLogo.full] affiche le logo complet (écrans de lancement, connexion,
/// inscription…).
class BrandLogo extends StatelessWidget {
  const BrandLogo({
    super.key,
    this.size = 28,
    this.showTagline = true,
    this.onDark = false,
  }) : full = false;

  /// Logo complet (emblème, nom et slogan) de hauteur [size].
  const BrandLogo.full({super.key, this.size = 160})
    : full = true,
      showTagline = true,
      onDark = false;

  static const fullAsset = 'assets/images/logo.png';
  static const markAsset = 'assets/images/logo_mark.png';

  final double size;
  final bool showTagline;
  final bool onDark;
  final bool full;

  @override
  Widget build(BuildContext context) {
    if (full) {
      return Image.asset(
        fullAsset,
        height: size,
        fit: BoxFit.contain,
        semanticLabel: 'Partage+ — Partager plutôt que jeter',
      );
    }

    final main = onDark ? Colors.white : AppColors.primary;

    // Réduit plutôt que déborder sur les écrans étroits.
    return FittedBox(
      fit: BoxFit.scaleDown,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: size * 1.4,
            height: size * 1.4,
            padding: EdgeInsets.all(onDark ? size * 0.12 : 0),
            decoration: onDark
                ? const BoxDecoration(
                    color: Colors.white,
                    shape: BoxShape.circle,
                  )
                : null,
            child: Image.asset(markAsset, fit: BoxFit.contain),
          ),
          SizedBox(width: size * 0.35),
          Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text.rich(
                TextSpan(
                  children: [
                    TextSpan(
                      text: 'Partage',
                      style: TextStyle(color: main),
                    ),
                    const TextSpan(
                      text: '+',
                      style: TextStyle(color: AppColors.accent),
                    ),
                  ],
                ),
                style: TextStyle(
                  fontSize: size,
                  fontWeight: FontWeight.w800,
                  height: 1,
                  letterSpacing: -0.5,
                ),
              ),
              if (showTagline) ...[
                SizedBox(height: size * 0.12),
                Text(
                  'Partager plutôt que jeter',
                  style: TextStyle(
                    fontSize: size * 0.38,
                    color: onDark ? Colors.white70 : AppColors.primary,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }
}
