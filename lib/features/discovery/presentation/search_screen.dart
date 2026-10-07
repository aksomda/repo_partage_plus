import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:repo_partage_plus/core/location/location.dart';
import 'package:repo_partage_plus/core/theme/app_theme.dart';
import 'package:repo_partage_plus/features/discovery/presentation/widgets/discovery_widgets.dart';
import 'package:repo_partage_plus/features/offers/data/offers_repository.dart';
import 'package:repo_partage_plus/core/widgets/app_menu.dart';
import 'package:repo_partage_plus/core/router/app_routes.dart';

/// Offres disponibles (maquette « Liste des offres ») : recherche, filtres
/// et catégories, autour du point de départ (sans compte aussi).
class SearchScreen extends ConsumerWidget {
  const SearchScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final count = filterOffers(
      ref.watch(availableOffersProvider),
      ref.watch(originProvider).place,
      const OfferFilters(),
    ).length;
    return Scaffold(
      drawer: const AppMenu(currentLocation: AppRoutes.search),
      appBar: AppBar(
        leading: backOrMenuButton(context),
        title: const Text('Offres disponibles'),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 16),
            child: Center(
              child: Text(
                count <= 1 ? '$count offre' : '$count offres',
                style: const TextStyle(color: AppColors.textMuted),
              ),
            ),
          ),
        ],
      ),
      body: const Column(
        children: [
          OriginBar(),
          Divider(),
          Expanded(child: OffersBrowser(autofocusSearch: true)),
        ],
      ),
    );
  }
}
