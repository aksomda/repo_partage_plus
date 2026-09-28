import 'package:flutter/material.dart';

import 'package:repo_partage_plus/core/theme/app_theme.dart';

/// Logo texte « Partage+ » avec pictogramme et slogan optionnel.
///
/// [onDark] pour l'afficher sur fond vert (barre latérale admin, bandeaux).
class BrandLogo extends StatelessWidget {
  const BrandLogo({
    super.key,
    this.size = 28,
    this.showTagline = true,
    this.onDark = false,
  });

  final double size;
  final bool showTagline;
  final bool onDark;

  @override
  Widget build(BuildContext context) {
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
            decoration: BoxDecoration(
              color: onDark ? Colors.white : AppColors.primarySoft,
              shape: BoxShape.circle,
            ),
            child: Icon(
              Icons.volunteer_activism,
              size: size * 0.8,
              color: AppColors.leaf,
            ),
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
