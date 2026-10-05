import 'package:flutter_test/flutter_test.dart';

import 'package:repo_partage_plus/core/router/app_routes.dart';
import 'package:repo_partage_plus/features/notifications/data/chat_repository.dart';
import 'package:repo_partage_plus/features/pickup/domain/pickup_qr.dart';

void main() {
  group('QR code de retrait', () {
    test('aller-retour : le code est relu depuis le QR', () {
      final data = pickupQrData(42, '012345');
      expect(pickupCodeFromQr(data, reservationId: 42), '012345');
    });

    test('QR d’une autre réservation refusé', () {
      final data = pickupQrData(42, '012345');
      expect(pickupCodeFromQr(data, reservationId: 7), isNull);
    });

    test('code seul accepté, texte quelconque refusé', () {
      expect(pickupCodeFromQr(' 654321 '), '654321');
      expect(pickupCodeFromQr('https://exemple.org/123456'), isNull);
    });
  });

  group('lien d’une notification', () {
    test('réservation confirmée : fiche de la réservation', () {
      expect(
        notificationLink({
          'type': 'reservation_confirmed',
          'data': '{"reservation_id": 5, "offer_id": 9}',
        }),
        AppRoutes.confirmation('5'),
      );
    });

    test('nouvelle réservation (donateur) : liste des réservations', () {
      expect(
        notificationLink({
          'type': 'reservation_created',
          'data': {'reservation_id': 5, 'offer_id': 9},
        }),
        AppRoutes.myReservations,
      );
    });

    test('DLC proche : fiche de l’offre ; compte : aucun lien', () {
      expect(
        notificationLink({
          'type': 'expiry_soon',
          'data': {'offer_id': 9},
        }),
        AppRoutes.offer('9'),
      );
      expect(notificationLink({'type': 'account_status'}), isNull);
    });
  });
}
