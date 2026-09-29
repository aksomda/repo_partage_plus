/// Chemins de toutes les routes de l'application.
///
/// Toujours naviguer via ces constantes (ou les helpers) plutôt qu'avec
/// des chaînes en dur, pour que les renommages restent centralisés.
abstract final class AppRoutes {
  // Auth
  static const splash = '/';
  static const login = '/login';
  static const register = '/register';
  static const verifyEmail = '/verify-email';
  static String verifyEmailFor(String email) =>
      Uri(path: verifyEmail, queryParameters: {'email': email}).toString();
  static const profile = '/profile';

  // Découverte
  static const home = '/home';
  static const nearbyMap = '/discovery/map';
  static const search = '/discovery/search';

  // Offres
  static const myOffers = '/offers/mine';
  static const createOffer = '/offers/new';
  static const offerDetail = '/offers/:id';
  static String offer(String id) => '/offers/$id';

  // Réservations
  static const myReservations = '/reservations';
  static const reservationConfirmation = '/reservations/:id/confirmation';
  static String confirmation(String id) => '/reservations/$id/confirmation';

  // Retrait
  static const pickupPattern = '/pickup/:reservationId';
  static String pickup(String reservationId) => '/pickup/$reservationId';

  // Notifications, impact, recommandations
  static const notifications = '/notifications';
  static const impact = '/impact';
  static const recommendations = '/recommendations';

  // Administration
  static const adminDashboard = '/admin';
  static const adminOffers = '/admin/offers';
  static const adminAccounts = '/admin/accounts';
  static const adminAssociations = '/admin/associations';
  static const adminCategories = '/admin/categories';
  static const adminFactors = '/admin/factors';
  static const adminActors = '/admin/actors';

  /// Écran d'arrivée après connexion, selon les droits du profil.
  static String homeFor(Object? profile) =>
      profile is Map && profile['role'] == 'admin' ? adminAccounts : home;
}

/// Entrée du menu de développement listant tous les écrans.
class RouteMenuEntry {
  const RouteMenuEntry(this.title, this.location);

  final String title;
  final String location;
}

/// Tous les écrans déclarés, utilisé par le menu placeholder et les tests.
final List<RouteMenuEntry> allRouteEntries = [
  const RouteMenuEntry('Démarrage', AppRoutes.splash),
  const RouteMenuEntry('Connexion', AppRoutes.login),
  const RouteMenuEntry('Inscription', AppRoutes.register),
  const RouteMenuEntry('Activation du compte', AppRoutes.verifyEmail),
  const RouteMenuEntry('Profil', AppRoutes.profile),
  const RouteMenuEntry('Accueil', AppRoutes.home),
  const RouteMenuEntry('Offres à proximité', AppRoutes.nearbyMap),
  const RouteMenuEntry('Recherche', AppRoutes.search),
  const RouteMenuEntry('Mes offres', AppRoutes.myOffers),
  const RouteMenuEntry('Publier une offre', AppRoutes.createOffer),
  RouteMenuEntry("Détail de l'offre", AppRoutes.offer('1')),
  const RouteMenuEntry('Mes réservations', AppRoutes.myReservations),
  RouteMenuEntry('Confirmation de réservation', AppRoutes.confirmation('1')),
  RouteMenuEntry('Retrait', AppRoutes.pickup('1')),
  const RouteMenuEntry('Notifications', AppRoutes.notifications),
  const RouteMenuEntry('Mon impact', AppRoutes.impact),
  const RouteMenuEntry('Recommandations', AppRoutes.recommendations),
  const RouteMenuEntry('Administration', AppRoutes.adminDashboard),
  const RouteMenuEntry('Modération des offres', AppRoutes.adminOffers),
  const RouteMenuEntry('Modération des comptes', AppRoutes.adminAccounts),
  const RouteMenuEntry(
    'Validation des associations',
    AppRoutes.adminAssociations,
  ),
  const RouteMenuEntry('Catégories', AppRoutes.adminCategories),
  const RouteMenuEntry('Facteurs', AppRoutes.adminFactors),
  const RouteMenuEntry('Acteurs', AppRoutes.adminActors),
];
