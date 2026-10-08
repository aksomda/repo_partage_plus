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
