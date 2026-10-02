import '../domain/entities/app_notification.dart';

final DateTime notificationNow = DateTime.now();

final List<AppNotification> mockNotifications = [
  AppNotification(
    id: 'notification_001',
    type: AppNotificationType.offer,
    title: 'Nouvelle offre favorite',
    message:
        'Boulangerie du Marché publie un panier à 1 500 FCFA, à 450 m.',
    createdAt: notificationNow.subtract(const Duration(minutes: 5)),
  ),
  AppNotification(
    id: 'notification_002',
    type: AppNotificationType.reminder,
    title: 'Rappel de retrait',
    message:
        'Votre créneau 19:30 – 20:00 commence dans 30 minutes. Code P+ 4829.',
    createdAt: notificationNow.subtract(const Duration(minutes: 42)),
  ),
  AppNotification(
    id: 'notification_003',
    type: AppNotificationType.reservation,
    title: 'Réservation confirmée',
    message: 'Panier boulangerie du soir ×1 est réservé.',
    createdAt: notificationNow.subtract(const Duration(hours: 1)),
  ),
  AppNotification(
    id: 'notification_004',
    type: AppNotificationType.expiration,
    title: 'Expire bientôt',
    message:
        'Les yaourts gratuits de Supérette Faso expirent demain matin.',
    createdAt: notificationNow.subtract(const Duration(hours: 2)),
    isRead: true,
  ),
  AppNotification(
    id: 'notification_005',
    type: AppNotificationType.impact,
    title: 'Nouveau palier atteint',
    message: 'Bravo, 10 produits sauvés ce mois-ci ! Badge Argent débloqué.',
    createdAt: notificationNow.subtract(const Duration(days: 1)),
    isRead: true,
  ),
  AppNotification(
    id: 'notification_006',
    type: AppNotificationType.offer,
    title: '3 offres près de chez vous',
    message:
        'Selon vos préférences : plats cuisinés et fruits & légumes.',
    createdAt: notificationNow.subtract(const Duration(days: 1, hours: 3)),
    isRead: true,
  ),
];