import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:repo_partage_plus/core/theme/app_theme.dart';
import 'package:repo_partage_plus/features/favorites/data/favorites.dart';

/// Cœur : ajoute ou retire l'offre des favoris (sans compte aussi).
class FavoriteButton extends ConsumerWidget {
  const FavoriteButton({
    super.key,
    required this.offerId,
    this.compact = false,
    this.filled = false,
  });

  final int offerId;

  /// Bouton réduit, pour les cartes de liste.
  final bool compact;

  /// Pastille blanche, pour un cœur posé sur une photo.
  final bool filled;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final favorite = ref.watch(
      favoritesProvider.select((f) => f.offerIds.contains(offerId)),
    );
    return IconButton(
      tooltip: favorite ? 'Retirer des favoris' : 'Ajouter aux favoris',
      visualDensity: compact ? VisualDensity.compact : null,
      style: filled
          ? IconButton.styleFrom(backgroundColor: Colors.white)
          : null,
      icon: Icon(
        favorite ? Icons.favorite : Icons.favorite_border,
        size: compact ? 20 : null,
        color: favorite
            ? AppColors.danger
            : compact
            ? AppColors.textMuted
            : null,
      ),
      onPressed: () =>
          ref.read(favoritesProvider.notifier).toggleOffer(offerId),
    );
  }
}
