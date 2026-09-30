import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'package:repo_partage_plus/core/location/location.dart';
import 'package:repo_partage_plus/core/router/app_routes.dart';
import 'package:repo_partage_plus/core/storage/local_store.dart';
import 'package:repo_partage_plus/core/theme/app_theme.dart';
import 'package:repo_partage_plus/core/widgets/brand_logo.dart';
import 'package:repo_partage_plus/features/auth/data/auth_repository.dart';

/// Écran d'accueil. Si une session existe déjà sur l'appareil, redirige
/// directement vers l'application (même hors ligne).
class SplashScreen extends ConsumerStatefulWidget {
  const SplashScreen({super.key});

  @override
  ConsumerState<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends ConsumerState<SplashScreen> {
  var _starting = false;

  /// Demande l'autorisation de localisation (téléphone, navigateur, Windows),
  /// puis ouvre les offres à proximité. En cas de refus, l'accueil propose
  /// de choisir un point de départ sur la carte.
  Future<void> _start() async {
    setState(() => _starting = true);
    await ref.read(originProvider.notifier).useCurrentPosition();
    if (!mounted) return;
    setState(() => _starting = false);
    context.go(AppRoutes.home);
  }

  @override
  void initState() {
    super.initState();
    if (ref.read(isLoggedInProvider)) _openApp();
  }

  Future<void> _openApp() async {
    // Profil lu directement : le flux local n'a peut-être pas encore émis.
    final profile = await ref.read(localStoreProvider).readSnapshot('profile');
    if (!mounted) return;
    context.go(AppRoutes.homeFor(profile));
  }

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;

    return Scaffold(
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Colors.white, AppColors.primarySoft],
          ),
        ),
        child: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(32),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 400),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const SizedBox(height: 24),
                    const Center(child: BrandLogo(size: 40)),
                    const SizedBox(height: 48),
                    Text(
                      'Ensemble contre le gaspillage\n'
                      'pour un avenir plus durable !',
                      textAlign: TextAlign.center,
                      style: textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                        height: 1.4,
                      ),
                    ),
                    const SizedBox(height: 12),
                    Text(
                      'Récupérez les invendus des commerces et restaurants '
                      'près de chez vous, ou publiez les vôtres.',
                      textAlign: TextAlign.center,
                      style: textTheme.bodyMedium?.copyWith(
                        color: AppColors.textMuted,
                      ),
                    ),
                    const SizedBox(height: 48),
                    FilledButton.icon(
                      onPressed: _starting ? null : _start,
                      icon: _starting
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: Colors.white,
                              ),
                            )
                          : const Icon(Icons.near_me_outlined),
                      label: const Text('Commencer'),
                    ),
                    const SizedBox(height: 4),
                    const Text(
                      'Voir les offres autour de vous, sans compte',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: AppColors.textMuted,
                        fontSize: 12,
                      ),
                    ),
                    const SizedBox(height: 16),
                    OutlinedButton(
                      onPressed: () => context.push(AppRoutes.register),
                      child: const Text('S’inscrire'),
                    ),
                    const SizedBox(height: 8),
                    Wrap(
                      alignment: WrapAlignment.center,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        const Text(
                          'Déjà un compte ?',
                          style: TextStyle(color: AppColors.textMuted),
                        ),
                        TextButton(
                          onPressed: () => context.push(AppRoutes.login),
                          child: const Text('Se connecter'),
                        ),
                      ],
                    ),
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
