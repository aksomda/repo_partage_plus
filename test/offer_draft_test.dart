import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:repo_partage_plus/core/network/api_client.dart';
import 'package:repo_partage_plus/core/offline/offline_data.dart';
import 'package:repo_partage_plus/features/auth/data/auth_repository.dart';
import 'package:repo_partage_plus/features/offers/data/offer_draft.dart';
import 'package:repo_partage_plus/features/offers/presentation/widgets/express_draft_card.dart';

/// Faux serveur : renvoie [result] ou lève [error].
class _FakeDrafts implements OfferDraftRepository {
  _FakeDrafts({this.result, this.error});

  final Json? result;
  final Object? error;
  final texts = <String>[];

  @override
  Future<Json> draft(String text, {DateTime? now}) async {
    texts.add(text);
    if (error != null) throw error!;
    return result!;
  }
}

void main() {
  group('publication express : dates du brouillon', () {
    final now = DateTime(2026, 10, 5, 17, 30);

    test('DLC et créneau calculés à partir de l’heure de l’appareil', () {
      final dates = draftDates({
        'expiry_in_days': 1,
        'pickup_start': '18:00',
        'pickup_end': '20:00',
      }, now);
      expect(dates.expiry, DateTime(2026, 10, 6));
      expect(dates.pickupStart, DateTime(2026, 10, 5, 18));
      expect(dates.pickupEnd, DateTime(2026, 10, 5, 20));
    });

    test('sans début : retrait possible tout de suite', () {
      final dates = draftDates({'pickup_end': '20:00'}, now);
      expect(dates.pickupStart, now);
      expect(dates.expiry, isNull);
    });

    test('heure de fin déjà passée : créneau non modifié', () {
      final dates = draftDates({'pickup_end': '12:00'}, now);
      expect(dates.pickupStart, isNull);
      expect(dates.pickupEnd, isNull);
    });
  });

  group('publication express : accès', () {
    ProviderContainer container(Json? profile, {bool loggedIn = true}) =>
        ProviderContainer(
          overrides: [
            isLoggedInProvider.overrideWithValue(loggedIn),
            profileProvider.overrideWithValue(profile),
          ],
        );

    test('réservée aux restaurateurs connectés', () {
      expect(
        container({
          'actor_code': 'restaurateur',
        }).read(canUseExpressDraftProvider),
        isTrue,
      );
      expect(
        container({
          'actor_code': 'commercant',
        }).read(canUseExpressDraftProvider),
        isFalse,
      );
      expect(
        container({
          'actor_code': 'restaurateur',
        }, loggedIn: false).read(canUseExpressDraftProvider),
        isFalse,
      );
    });
  });

  group('publication express : carte', () {
    Future<List<Json>> pump(WidgetTester tester, _FakeDrafts drafts) async {
      final received = <Json>[];
      await tester.pumpWidget(
        ProviderScope(
          overrides: [offerDraftRepositoryProvider.overrideWithValue(drafts)],
          child: MaterialApp(
            home: Scaffold(body: ExpressDraftCard(onDraft: received.add)),
          ),
        ),
      );
      return received;
    }

    testWidgets('le brouillon est transmis au formulaire', (tester) async {
      final drafts = _FakeDrafts(result: {'title': 'Riz gras', 'quantity': 5});
      final received = await pump(tester, drafts);
      await tester.enterText(find.byType(TextField), '5 plats de riz gras');
      await tester.tap(find.text('Remplir avec l’IA'));
      await tester.pumpAndSettle();
      expect(drafts.texts, ['5 plats de riz gras']);
      expect(received.single['title'], 'Riz gras');
      expect(find.textContaining('Formulaire pré-rempli'), findsOneWidget);
    });

    testWidgets('IA indisponible : message, formulaire inchangé', (
      tester,
    ) async {
      final drafts = _FakeDrafts(
        error: ApiException('Service d’IA indisponible', statusCode: 503),
      );
      final received = await pump(tester, drafts);
      await tester.enterText(find.byType(TextField), '5 plats de riz gras');
      await tester.tap(find.text('Remplir avec l’IA'));
      await tester.pumpAndSettle();
      expect(received, isEmpty);
      expect(find.textContaining('Service d’IA indisponible'), findsOneWidget);
    });
  });
}
