import 'package:flutter/material.dart';

/// Chemins de toutes les routes de l'application.
///
/// Toujours naviguer via ces constantes (ou les helpers) plutôt qu'avec
/// des chaînes en dur, pour que les renommages restent centralisés.
abstract final class AppRoutes {
  // Auth
  static const splash = '/';
  static const login = '/login';
  static const register = '/register';
  static const forgotPassword = '/forgot-password';
  static String forgotPasswordFor(String email) =>
      Uri(path: forgotPassword, queryParameters: {'email': email}).toString();
  static const verifyEmail = '/verify-email';
  static String verifyEmailFor(String email) =>
      Uri(path: verifyEmail, queryParameters: {'email': email}).toString();
  static const profile = '/profile';

  // Découverte
  static const home = '/home';
  static const nearbyMap = '/discovery/map';
  static const search = '/discovery/search';
  static const filters = '/discovery/filters';
  static const pickLocation = '/discovery/location';
  static const offline = '/offline';

  // Offres
  static const myOffers = '/offers/mine';
  static const createOffer = '/offers/new';
  static const offerDetail = '/offers/:id';
  static String offer(String id) => '/offers/$id';
  static const editOfferPattern = '/offers/:id/edit';
  static String editOffer(Object id) => '/offers/$id/edit';
  static const reservePattern = '/offers/:id/reserve';
  static String reserve(Object id) => '/offers/$id/reserve';

  // Réservations
  static const myReservations = '/reservations';
  static const reservationConfirmation = '/reservations/:id/confirmation';
  static String confirmation(String id) => '/reservations/$id/confirmation';

  // Retrait
  static const pickupPattern = '/pickup/:reservationId';
  static String pickup(String reservationId) => '/pickup/$reservationId';

  // Notifications, impact, recommandations
  static const notifications = '/notifications';
  static const messages = '/notifications/messages';
  static const teamMessages = '/notifications/messages/team';
  static const directConversationPattern =
      '/notifications/messages/user/:peerId';

  /// Échange avec un autre utilisateur ; [offerId] : offre dont on parle.
  static String directConversation(int peerId, {int? offerId}) => Uri(
    path: '/notifications/messages/user/$peerId',
    queryParameters: offerId == null ? null : {'offer': '$offerId'},
  ).toString();
  static const conversationPattern = '/notifications/conversation/:userId';
  static String conversation(int userId) =>
      '/notifications/conversation/$userId';
  static const impact = '/impact';
  static const recommendations = '/recommendations';

  // Administration
  static const adminDashboard = '/admin';
  static const adminOffers = '/admin/offers';
  static const adminAccounts = '/admin/accounts';
  static const adminCategories = '/admin/categories';
  static const adminFactors = '/admin/factors';
  static const adminActors = '/admin/actors';
  static const adminSettings = '/admin/settings';
  static const adminReservations = '/admin/reservations';
  static const adminImpact = '/admin/impact';
  static const adminManage = '/admin/manage';

  /// Écrans réservés aux comptes connectés : redirigés vers la connexion.
  static bool requiresLogin(String path) =>
      path == profile ||
      path == notifications ||
      path.startsWith('/notifications/') ||
      path == impact ||
      path.startsWith('/pickup/') ||
      path == adminDashboard ||
      path.startsWith('/admin/');

  /// Écrans réservés aux administrateurs.
  static bool requiresAdmin(String path) =>
      path == adminDashboard || path.startsWith('/admin/');

  static String loginThen(String from) =>
      Uri(path: login, queryParameters: {'from': from}).toString();

  static String loginWith(String email) =>
      Uri(path: login, queryParameters: {'email': email}).toString();

  /// Écran d'arrivée après connexion, selon les droits du profil.
  static String homeFor(Object? profile) =>
      profile is Map && profile['role'] == 'admin' ? adminAccounts : home;
}

/// Bloc thématique du menu (tiroir).
enum MenuGroup {
  home('Accueil', Icons.home_outlined),
  offers('Offres', Icons.storefront_outlined),
  reservations('Réservations', Icons.event_available_outlined),
  pickups('Retraits', Icons.qr_code_2_outlined),
  notifications('Notifications', Icons.notifications_none),
  impacts('Impacts par donateur', Icons.eco_outlined),
  administration('Administration', Icons.admin_panel_settings_outlined);

  const MenuGroup(this.title, this.icon);

  final String title;
  final IconData icon;
}

/// Entrée du menu listant tous les écrans, rangée dans un bloc thématique.
class RouteMenuEntry {
  const RouteMenuEntry(this.title, this.location, this.group);

  final String title;
  final String location;
  final MenuGroup group;
}

/// Tous les écrans déclarés, par bloc ; utilisé par le menu et les tests.
final List<RouteMenuEntry> allRouteEntries = [
  // Accueil
  const RouteMenuEntry('Démarrage', AppRoutes.splash, MenuGroup.home),
  const RouteMenuEntry('Accueil', AppRoutes.home, MenuGroup.home),
  const RouteMenuEntry('Offres disponibles', AppRoutes.search, MenuGroup.home),
  const RouteMenuEntry('Filtres', AppRoutes.filters, MenuGroup.home),
  const RouteMenuEntry('Mode hors ligne', AppRoutes.offline, MenuGroup.home),
  const RouteMenuEntry(
    'Point de départ',
    AppRoutes.pickLocation,
    MenuGroup.home,
  ),
  const RouteMenuEntry('Connexion', AppRoutes.login, MenuGroup.home),
  const RouteMenuEntry('Inscription', AppRoutes.register, MenuGroup.home),
  const RouteMenuEntry(
    'Activation du compte',
    AppRoutes.verifyEmail,
    MenuGroup.home,
  ),
  const RouteMenuEntry(
    'Mot de passe oublié',
    AppRoutes.forgotPassword,
    MenuGroup.home,
  ),
  const RouteMenuEntry('Profil', AppRoutes.profile, MenuGroup.home),
  // Offres
  const RouteMenuEntry(
    'Offres à proximité',
    AppRoutes.nearbyMap,
    MenuGroup.offers,
  ),
  const RouteMenuEntry(
    'Publier une offre',
    AppRoutes.createOffer,
    MenuGroup.offers,
  ),
  const RouteMenuEntry('Mes offres', AppRoutes.myOffers, MenuGroup.offers),
  RouteMenuEntry("Détail de l'offre", AppRoutes.offer('1'), MenuGroup.offers),
  const RouteMenuEntry(
    'Recommandations',
    AppRoutes.recommendations,
    MenuGroup.offers,
  ),
  // Réservations
  RouteMenuEntry('Réserver', AppRoutes.reserve(1), MenuGroup.reservations),
  const RouteMenuEntry(
    'Mes réservations',
    AppRoutes.myReservations,
    MenuGroup.reservations,
  ),
  RouteMenuEntry(
    'Confirmation de réservation',
    AppRoutes.confirmation('1'),
    MenuGroup.reservations,
  ),
  // Retraits
  RouteMenuEntry('Retrait', AppRoutes.pickup('1'), MenuGroup.pickups),
  // Notifications
  const RouteMenuEntry(
    'Notifications',
    AppRoutes.notifications,
    MenuGroup.notifications,
  ),
  const RouteMenuEntry('Messages', AppRoutes.messages, MenuGroup.notifications),
  const RouteMenuEntry(
    'Équipe Partage+',
    AppRoutes.teamMessages,
    MenuGroup.notifications,
  ),
  // Impacts par donateur
  const RouteMenuEntry('Mon impact', AppRoutes.impact, MenuGroup.impacts),
  const RouteMenuEntry(
    'Facteurs d’impact',
    AppRoutes.adminFactors,
    MenuGroup.impacts,
  ),
  // Administration
  const RouteMenuEntry(
    'Tableau de bord',
    AppRoutes.adminDashboard,
    MenuGroup.administration,
  ),
  const RouteMenuEntry(
    'Administration',
    AppRoutes.adminManage,
    MenuGroup.administration,
  ),
  const RouteMenuEntry(
    'Réservations de la plateforme',
    AppRoutes.adminReservations,
    MenuGroup.administration,
  ),
  const RouteMenuEntry(
    'Impact de la plateforme',
    AppRoutes.adminImpact,
    MenuGroup.administration,
  ),
  const RouteMenuEntry(
    'Modération des offres',
    AppRoutes.adminOffers,
    MenuGroup.administration,
  ),
  const RouteMenuEntry(
    'Gestion des utilisateurs',
    AppRoutes.adminAccounts,
    MenuGroup.administration,
  ),
  const RouteMenuEntry(
    'Catégories',
    AppRoutes.adminCategories,
    MenuGroup.administration,
  ),
  const RouteMenuEntry(
    'Acteurs',
    AppRoutes.adminActors,
    MenuGroup.administration,
  ),
  const RouteMenuEntry(
    'Paramètres',
    AppRoutes.adminSettings,
    MenuGroup.administration,
  ),
];
