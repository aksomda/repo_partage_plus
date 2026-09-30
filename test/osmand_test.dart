import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:repo_partage_plus/core/maps/external_maps.dart';
import 'package:repo_partage_plus/core/router/app_router.dart';
import 'package:repo_partage_plus/core/router/app_routes.dart';

import 'helpers.dart';

/// Faux OsmAnd : installé ou non, enregistre les demandes.
class FakeMaps implements ExternalMaps {
  FakeMaps({required this.installed});

  final bool installed;
  final calls = <String>[];

  @override
  Future<MapLaunch> openInOsmAnd(double lat, double lng) async {
    calls.add('osmand $lat,$lng');
    return installed ? MapLaunch.osmand : MapLaunch.osmandMissing;
  }

  @override
  Future<MapLaunch> openInOtherApp(double lat, double lng, String label) async {
    calls.add('other $label');
    return MapLaunch.otherApp;
  }

  @override
  Future<void> installOsmAnd() async => calls.add('install');
}

Future<void> pumpOffer(WidgetTester tester, FakeMaps maps) async {
  final store = (await tester.runAsync(memoryStore))!;
  await tester.runAsync(
    () => store.saveSnapshot({
      'offers': [
        publishedOffer(id: 1, title: 'Panier', lat: 12.38, lng: -1.51),
      ],
    }),
  );
  final overrides = await tester.runAsync(() => testOverrides(store: store));
  final router = createRouter(initialLocation: AppRoutes.offer('1'));
  addTearDown(router.dispose);

  await tester.pumpWidget(
    ProviderScope(
      overrides: [...overrides!, externalMapsProvider.overrideWithValue(maps)],
      child: MaterialApp.router(routerConfig: router),
    ),
  );
  await tester.pumpAndSettle();
  await tester.ensureVisible(find.text('Itinéraire avec OsmAnd'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('OsmAnd installé : ouvert directement sur le lieu de retrait', (
    tester,
  ) async {
    final maps = FakeMaps(installed: true);
    await pumpOffer(tester, maps);

    await tester.tap(find.text('Itinéraire avec OsmAnd'));
    await tester.pumpAndSettle();

    expect(maps.calls, ['osmand 12.38,-1.51']);
    expect(find.text('OsmAnd n’est pas installé'), findsNothing);
  });

  testWidgets('OsmAnd absent : installation ou autre application proposées', (
    tester,
  ) async {
    final maps = FakeMaps(installed: false);
    await pumpOffer(tester, maps);

    await tester.tap(find.text('Itinéraire avec OsmAnd'));
    await tester.pumpAndSettle();
    expect(find.text('OsmAnd n’est pas installé'), findsOneWidget);

    await tester.tap(find.text('Autre application'));
    await tester.pumpAndSettle();
    expect(maps.calls.last, 'other Panier');

    await tester.tap(find.text('Itinéraire avec OsmAnd'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Installer OsmAnd'));
    await tester.pumpAndSettle();
    expect(maps.calls.last, 'install');
  });
}
