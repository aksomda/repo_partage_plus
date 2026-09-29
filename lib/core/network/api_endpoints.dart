/// Chemins de l'API (relatifs à ApiConfig.baseUrl). Détail dans server/README.md.
abstract final class ApiEndpoints {
  /// Instantané complet pour le mode hors ligne.
  static const sync = '/sync';

  // Auth et profil
  static const register = '/auth/register';
  static const login = '/auth/login';
  static const firebaseSession = '/auth/firebase';
  static const verifyEmail = '/auth/verify-email';
  static const resendCode = '/auth/resend-code';
  static const me = '/auth/me';
  static const updateMe = '/users/me';
  static const changePassword = '/users/me/password';

  // Référentiels
  static const categories = '/categories';
  static const factors = '/factors';
  static const actors = '/actors';

  // Offres
  static const offers = '/offers';
  static const nearbyOffers = '/offers/nearby';
  static const expiringOffers = '/offers/expiring-soon';
  static const myOffers = '/offers/mine';
  static String offer(int id) => '/offers/$id';

  // Réservations et retrait
  static const reservations = '/reservations';
  static const myReservations = '/reservations/mine';
  static const receivedReservations = '/reservations/received';
  static String reservation(int id) => '/reservations/$id';
  static String confirmReservation(int id) => '/reservations/$id/confirm';
  static String cancelReservation(int id) => '/reservations/$id/cancel';
  static String pickup(int id) => '/reservations/$id/pickup';

  // Notifications
  static const notifications = '/notifications';
  static const unreadCount = '/notifications/unread-count';
  static const readAllNotifications = '/notifications/read-all';
  static String readNotification(int id) => '/notifications/$id/read';

  // Impact et recommandations
  static const myImpact = '/impact/me';
  static const globalImpact = '/impact/global';
  static const recommendations = '/recommendations';

  // Administration
  static const adminStats = '/admin/stats';
  static const adminOffers = '/admin/offers';
  static String moderateOffer(int id) => '/admin/offers/$id/moderation';
  static const adminUsers = '/admin/users';
  static String userStatus(int id) => '/admin/users/$id/status';
  static const adminAssociations = '/admin/associations';
  static String reviewAssociation(int id) => '/admin/associations/$id/review';
  static const adminCategories = '/admin/categories';
  static String adminCategory(int id) => '/admin/categories/$id';
  static const adminActors = '/admin/actors';
  static String adminActor(int id) => '/admin/actors/$id';
  static const adminFactors = '/admin/factors';
  static String adminFactor(int id) => '/admin/factors/$id';
  static const runJobs = '/admin/jobs/run';
}
