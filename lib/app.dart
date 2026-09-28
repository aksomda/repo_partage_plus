import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:repo_partage_plus/core/offline/offline_banner.dart';
import 'package:repo_partage_plus/core/offline/sync_controller.dart';
import 'package:repo_partage_plus/core/router/app_router.dart';
import 'package:repo_partage_plus/core/theme/app_theme.dart';

class RepasPartageApp extends ConsumerWidget {
  const RepasPartageApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Démarre la synchronisation automatique pour toute la durée de l'app.
    ref.watch(syncControllerProvider);

    return MaterialApp.router(
      title: 'Partage+',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light(),
      routerConfig: ref.watch(routerProvider),
      builder: (context, child) => OfflineBanner(child: child!),
    );
  }
}
