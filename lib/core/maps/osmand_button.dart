import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:repo_partage_plus/core/maps/external_maps.dart';
import 'package:repo_partage_plus/core/theme/app_theme.dart';
import 'package:repo_partage_plus/features/auth/presentation/widgets/auth_widgets.dart';

/// Bouton « Itinéraire avec OsmAnd » vers un lieu de retrait. OsmAnd guide
/// sans connexion si la carte de la région a été téléchargée dans l'app.
class OsmAndButton extends ConsumerWidget {
  const OsmAndButton({
    super.key,
    required this.lat,
    required this.lng,
    required this.label,
  });

  final double lat;
  final double lng;
  final String label;

  Future<void> _open(BuildContext context, WidgetRef ref) async {
    final maps = ref.read(externalMapsProvider);
    final result = await maps.openInOsmAnd(lat, lng);
    if (!context.mounted) return;

    switch (result) {
      case MapLaunch.osmand || MapLaunch.otherApp:
        return;
      case MapLaunch.web:
        showMessage(context, 'Carte OsmAnd ouverte dans le navigateur');
      case MapLaunch.failed:
        showMessage(context, 'Impossible d’ouvrir la carte', error: true);
      case MapLaunch.osmandMissing:
        final choice = await showDialog<String>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('OsmAnd n’est pas installé'),
            content: const Text(
              'OsmAnd est une application de cartes gratuite qui guide '
              'jusqu’au lieu de retrait même sans connexion, une fois la '
              'carte de votre pays téléchargée.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop('other'),
                child: const Text('Autre application'),
              ),
              FilledButton(
                onPressed: () => Navigator.of(context).pop('install'),
                child: const Text('Installer OsmAnd'),
              ),
            ],
          ),
        );
        if (choice == 'install') await maps.installOsmAnd();
        if (choice == 'other') {
          final other = await maps.openInOtherApp(lat, lng, label);
          if (other == MapLaunch.failed && context.mounted) {
            showMessage(context, 'Aucune application de cartes', error: true);
          }
        }
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        OutlinedButton.icon(
          onPressed: () => _open(context, ref),
          icon: const Icon(Icons.directions_outlined),
          label: const Text('Itinéraire avec OsmAnd'),
        ),
        const SizedBox(height: 4),
        const Text(
          'Fonctionne hors connexion si la carte de la région est '
          'téléchargée dans OsmAnd.',
          style: TextStyle(color: AppColors.textMuted, fontSize: 12),
        ),
      ],
    );
  }
}
