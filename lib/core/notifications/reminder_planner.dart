/// Notification à afficher par l'appareil lui-même, sans le serveur.
class PlannedNotification {
  const PlannedNotification({
    required this.id,
    required this.at,
    required this.title,
    required this.body,
  });

  final int id;

  /// Instant d'affichage (UTC). Dans le passé = à afficher tout de suite.
  final DateTime at;
  final String title;
  final String body;
}

/// Calcule les rappels à programmer à partir des données locales, pour
/// qu'ils se déclenchent même si le téléphone reste hors ligne.
abstract final class ReminderPlanner {
  static const pickupReminderBefore = Duration(hours: 2);

  /// Heure locale de l'alerte DLC, la veille de la date limite.
  static const expiryAlertHour = 8;

  // Plages d'identifiants, pour retrouver et annuler nos notifications.
  static const pickupBase = 1000000;
  static const reservationExpiryBase = 2000000;
  static const offerExpiryBase = 3000000;
  static const serverBase = 4000000;
  static const rangeEnd = 5000000;

  static List<PlannedNotification> plan({
    required List<Map<String, dynamic>> reservations,
    required List<Map<String, dynamic>> myOffers,
    required DateTime now,
  }) {
    final today = DateTime(now.year, now.month, now.day);
    final planned = <PlannedNotification>[];

    for (final reservation in reservations) {
      final id = reservation['id'] as int;
      final status = reservation['status'];
      final title = reservation['offer_title'];
      final pickupStart = DateTime.parse(reservation['pickup_start'] as String);
      final pickupEnd = DateTime.parse(reservation['pickup_end'] as String);

      if (status == 'confirmed' && pickupEnd.isAfter(now)) {
        planned.add(
          PlannedNotification(
            id: pickupBase + id,
            at: pickupStart.subtract(pickupReminderBefore).toUtc(),
            title: 'Rappel de retrait',
            body:
                'Pensez à retirer « $title » (${reservation['address']}). '
                'Code : ${reservation['pickup_code']}.',
          ),
        );
      }

      if (status == 'pending' || status == 'confirmed') {
        final alert = _expiryAlert(
          reservation['expiry_date'] as String,
          today,
          id: reservationExpiryBase + id,
          body: '« $title » arrive à sa date limite : retirez-le vite.',
        );
        if (alert != null) planned.add(alert);
      }
    }

    for (final offer in myOffers) {
      final status = offer['status'];
      if (status != 'published' && status != 'reserved') continue;

      final alert = _expiryAlert(
        offer['expiry_date'] as String,
        today,
        id: offerExpiryBase + (offer['id'] as int),
        body:
            '« ${offer['title']} » arrive à sa date limite. '
            'Reste : ${offer['quantity_available']}.',
      );
      if (alert != null) planned.add(alert);
    }

    return planned;
  }

  static PlannedNotification? _expiryAlert(
    String expiryDate,
    DateTime today, {
    required int id,
    required String body,
  }) {
    final expiry = DateTime.parse(expiryDate);
    if (expiry.isBefore(today)) return null;

    final dayBefore = expiry.subtract(const Duration(days: 1));
    return PlannedNotification(
      id: id,
      at: DateTime(
        dayBefore.year,
        dayBefore.month,
        dayBefore.day,
        expiryAlertHour,
      ).toUtc(),
      title: 'DLC proche',
      body: body,
    );
  }
}
