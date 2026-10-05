import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'package:repo_partage_plus/core/location/location.dart';
import 'package:repo_partage_plus/core/network/api_client.dart';
import 'package:repo_partage_plus/core/offline/offline_data.dart';
import 'package:repo_partage_plus/core/router/app_routes.dart';
import 'package:repo_partage_plus/core/theme/app_theme.dart';
import 'package:repo_partage_plus/core/widgets/brand_logo.dart';
import 'package:repo_partage_plus/features/discovery/presentation/widgets/discovery_widgets.dart';
import 'package:repo_partage_plus/features/impact/data/impact_repository.dart';
import 'package:repo_partage_plus/features/notifications/data/chat_repository.dart';
import 'package:repo_partage_plus/features/offers/presentation/widgets/offer_widgets.dart';

/// Accueil : offres à proximité du point de départ, accessible sans compte.
class HomeScreen extends ConsumerStatefulWidget {
  const HomeScreen({super.key});

  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends ConsumerState<HomeScreen> {
  @override
  void initState() {
    super.initState();
    // Première ouverture sans position connue : on la demande.
    Future.microtask(() {
      final origin = ref.read(originProvider);
      if (origin.place == null && !origin.locating && origin.error == null) {
        ref.read(originProvider.notifier).useCurrentPosition();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final loggedIn = ref.watch(authTokenProvider) != null;

    return Scaffold(
      appBar: AppBar(
        // Sans compte : le logo ramène à l'écran d'accueil du démarrage.
        title: loggedIn
            ? const BrandLogo(size: 20, showTagline: false)
            : Tooltip(
                message: 'Retour à l’accueil',
                child: InkWell(
                  borderRadius: BorderRadius.circular(AppTheme.radius),
                  onTap: () => context.go(AppRoutes.splash),
                  child: const BrandLogo(size: 20, showTagline: false),
                ),
              ),
        actions: [
          IconButton(
            tooltip: 'Recommandations',
            icon: const Icon(Icons.auto_awesome_outlined),
            onPressed: () => context.push(AppRoutes.recommendations),
          ),
          IconButton(
            tooltip: 'Rechercher',
            icon: const Icon(Icons.search),
            onPressed: () => context.push(AppRoutes.search),
          ),
          if (loggedIn)
            IconButton(
              tooltip: 'Mon impact',
              icon: const Icon(Icons.eco_outlined),
              onPressed: () => context.push(AppRoutes.impact),
            ),
          if (loggedIn)
            IconButton(
              tooltip: 'Notifications',
              icon: Badge.count(
                count: ref.watch(unreadFeedCountProvider),
                isLabelVisible: ref.watch(unreadFeedCountProvider) > 0,
                child: const Icon(Icons.notifications_none),
              ),
              onPressed: () => context.push(AppRoutes.notifications),
            )
          else
            TextButton(
              onPressed: () => context.push(AppRoutes.login),
              child: const Text('Se connecter'),
            ),
        ],
      ),
      body: Column(
        children: [
          const OriginBar(),
          const Divider(),
          Expanded(
            child: OffersBrowser(header: _Banner(loggedIn: loggedIn)),
          ),
        ],
      ),
      bottomNavigationBar: const AppBottomNav(current: 0),
    );
  }
}

class _Banner extends ConsumerWidget {
  const _Banner({required this.loggedIn});

  final bool loggedIn;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final impact = ref.watch(publicImpactProvider);
    final saved = (impact?['food_kg'] as num?) ?? 0;
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [AppColors.primary, Color(0xFF2E9E4F)],
        ),
        borderRadius: BorderRadius.circular(AppTheme.radius + 4),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Moins de gaspillage,\nplus de solidarité !',
            style: TextStyle(
              color: Colors.white,
              fontSize: 20,
              fontWeight: FontWeight.w800,
              height: 1.2,
            ),
          ),
          // Rien de sauvé encore : pas de compteurs à zéro, peu engageants.
          if (impact != null && saved > 0) ...[
            const SizedBox(height: 12),
            _PlatformCounters(impact: impact),
          ],
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              FilledButton.icon(
                style: FilledButton.styleFrom(
                  backgroundColor: Colors.white,
                  foregroundColor: AppColors.primary,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 10,
                  ),
                ),
                onPressed: () => context.push(AppRoutes.createOffer),
                icon: const Icon(Icons.add),
                label: const Text('Publier une offre'),
              ),
              if (loggedIn)
                OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(
                    foregroundColor: Colors.white,
                    side: const BorderSide(color: Colors.white),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 10,
                    ),
                  ),
                  onPressed: () => context.push(AppRoutes.impact),
                  icon: const Icon(Icons.eco_outlined),
                  label: const Text('Mon impact'),
                ),
              if (!loggedIn)
                OutlinedButton(
                  style: OutlinedButton.styleFrom(
                    foregroundColor: Colors.white,
                    side: const BorderSide(color: Colors.white),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 10,
                    ),
                  ),
                  onPressed: () => context.push(AppRoutes.register),
                  child: const Text('S’inscrire'),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Ce que la communauté Partage+ a déjà sauvé (toute la plateforme).
class _PlatformCounters extends StatelessWidget {
  const _PlatformCounters({required this.impact});

  final Json impact;

  @override
  Widget build(BuildContext context) {
    num value(String key) => impact[key] as num? ?? 0;
    final counters = [
      (Icons.restaurant, formatNumber(value('meals')), 'repas'),
      (Icons.scale_outlined, formatNumber(value('food_kg')), 'kg sauvés'),
      (Icons.cloud_outlined, formatNumber(value('co2_kg')), 'kg CO₂ évités'),
      if (value('users') > 0)
        (Icons.groups_outlined, formatNumber(value('users')), 'membres'),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Ensemble, nous avons déjà sauvé :',
          style: TextStyle(color: Colors.white70),
        ),
        const SizedBox(height: 6),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final (icon, number, label) in counters)
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 6,
                ),
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.18),
                  borderRadius: BorderRadius.circular(AppTheme.radius),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(icon, size: 16, color: Colors.white),
                    const SizedBox(width: 6),
                    Text(
                      '$number $label',
                      style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ],
    );
  }
}
