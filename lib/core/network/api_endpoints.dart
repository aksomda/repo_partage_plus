/// Chemins de l'API (relatifs à ApiConfig.baseUrl). Détail dans server/README.md.
abstract final class ApiEndpoints {
  /// Instantané complet pour le mode hors ligne.
  static const sync = '/sync';

  /// Catalogue public (offres disponibles, catégories), sans compte.
  static const publicSync = '/sync/public';

  // Auth et profil
  static const register = '/auth/register';
  static const login = '/auth/login';
  static const firebaseSession = '/auth/firebase';
  static const verifyEmail = '/auth/verify-email';
  static const resendCode = '/auth/resend-code';
  static const forgotPassword = '/auth/password/forgot';
  static const resetPassword = '/auth/password/reset';
  static const releaseOrphan = '/auth/release-orphan';
  static const me = '/auth/me';
  static const updateMe = '/users/me';
  static const changePassword = '/users/me/password';
  static const devices = '/users/me/devices';
  static const donorAdvice = '/recommendations/advice';

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
  static String offerSlots(int id) => '/offers/$id/slots';

  // Réservations et retrait
  static const reservations = '/reservations';
  static const myReservations = '/reservations/mine';
  static const receivedReservations = '/reservations/received';
  static String reservation(int id) => '/reservations/$id';
  static String confirmReservation(int id) => '/reservations/$id/confirm';
  static String cancelReservation(int id) => '/reservations/$id/cancel';
  static String pickup(int id) => '/reservations/$id/pickup';
  static String guestReservation(int id) => '/reservations/guest/$id';

  // Notifications
  static const notifications = '/notifications';
  static const unreadCount = '/notifications/unread-count';
  static const readAllNotifications = '/notifications/read-all';
  static String readNotification(int id) => '/notifications/$id/read';

  // Mini chat avec l'administration
  static const messages = '/messages';
  static const readMessages = '/messages/read';
  static String messagePhoto(int id, int position) =>
      '/messages/$id/photos/$position';

  // Impact et recommandations
  static const myImpact = '/impact/me';
  static const myImpactDashboard = '/impact/me/dashboard';
  static const globalImpact = '/impact/global';
  static const myImpactByCategory = '/impact/me/by-category';
  static const myImpactMonthly = '/impact/me/monthly';
  static const globalImpactByCategory = '/impact/global/by-category';
  static const globalImpactMonthly = '/impact/global/monthly';
  static const recommendations = '/recommendations';
  static const refineRecommendations = '/recommendations/refine';

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
  static const adminSettings = '/admin/settings';
  static const runJobs = '/admin/jobs/run';
}
