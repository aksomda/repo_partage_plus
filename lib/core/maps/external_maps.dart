import 'package:android_intent_plus/android_intent.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

/// Résultat d'une demande d'itinéraire.
enum MapLaunch {
  /// Ouvert dans l'application OsmAnd (fonctionne hors ligne).
  osmand,

  /// Ouvert dans une autre application de cartes.
  otherApp,

  /// Ouvert dans la carte web OsmAnd (connexion requise).
  web,

  /// OsmAnd n'est pas installé sur l'appareil.
  osmandMissing,

  /// Rien n'a pu être ouvert.
  failed,
}

/// Ouverture d'un point dans OsmAnd, l'application de cartes et de
/// navigation hors ligne (cartes OpenStreetMap téléchargées sur l'appareil).
///
/// Android : lien `geo:` envoyé directement au paquet OsmAnd (format
/// documenté : https://osmand.net/docs/technical/algorithms/osmand-intents/).
/// Autres plateformes : OsmAnd ne documente pas de lien d'application, on
/// ouvre sa carte web.
abstract class ExternalMaps {
  Future<MapLaunch> openInOsmAnd(double lat, double lng);
  Future<MapLaunch> openInOtherApp(double lat, double lng, String label);
  Future<void> installOsmAnd();
}

class DefaultExternalMaps implements ExternalMaps {
  /// OsmAnd+ (payant) d'abord, puis la version gratuite.
  static const osmandPackages = ['net.osmand.plus', 'net.osmand'];

  bool get _android =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  @override
  Future<MapLaunch> openInOsmAnd(double lat, double lng) async {
    if (_android) {
      for (final package in osmandPackages) {
        final intent = AndroidIntent(
          action: 'action_view',
          data: 'geo:$lat,$lng?z=17',
          package: package,
        );
        try {
          if (await intent.canResolveActivity() ?? false) {
            await intent.launch();
            return MapLaunch.osmand;
          }
        } catch (_) {
          // Paquet absent ou refusé : on essaie le suivant.
        }
      }
      return MapLaunch.osmandMissing;
    }

    final web = Uri.parse('https://osmand.net/map/?pin=$lat,$lng#17/$lat/$lng');
    return await _open(web, mode: LaunchMode.externalApplication)
        ? MapLaunch.web
        : MapLaunch.failed;
  }

  @override
  Future<MapLaunch> openInOtherApp(double lat, double lng, String label) async {
    // Convention geo: reconnue par la plupart des applications de cartes.
    final geo = Uri.parse(
      'geo:$lat,$lng?q=$lat,$lng(${Uri.encodeComponent(label)})',
    );
    if (_android && await _open(geo)) return MapLaunch.otherApp;

    final web = Uri.parse(
      'https://www.openstreetmap.org/?mlat=$lat&mlon=$lng#map=17/$lat/$lng',
    );
    return await _open(web, mode: LaunchMode.externalApplication)
        ? MapLaunch.web
        : MapLaunch.failed;
  }

  @override
  Future<void> installOsmAnd() async {
    if (_android) {
      final store = Uri.parse('market://details?id=net.osmand');
      if (await _open(store)) return;
      await _open(
        Uri.parse('https://play.google.com/store/apps/details?id=net.osmand'),
        mode: LaunchMode.externalApplication,
      );
      return;
    }
    // Liens de téléchargement officiels (iOS, Android, autres).
    await _open(
      Uri.parse('https://osmand.net/'),
      mode: LaunchMode.externalApplication,
    );
  }
}

/// Aucune application pour ce lien : false plutôt qu'une exception.
Future<bool> _open(
  Uri uri, {
  LaunchMode mode = LaunchMode.platformDefault,
}) async {
  try {
    return await launchUrl(uri, mode: mode);
  } catch (_) {
    return false;
  }
}

final externalMapsProvider = Provider<ExternalMaps>(
  (ref) => DefaultExternalMaps(),
);
