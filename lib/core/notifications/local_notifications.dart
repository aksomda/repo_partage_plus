import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

import 'package:repo_partage_plus/core/location/location.dart';
import 'package:repo_partage_plus/core/notifications/reminder_planner.dart';
import 'package:repo_partage_plus/core/storage/local_store.dart';
import 'package:repo_partage_plus/features/favorites/data/favorites.dart';

/// Notifications affichées par l'appareil (Android, iOS, macOS, Windows,
/// Linux).
///
/// Sur le web, ou si init() n'a pas été appelé (tests), toutes les méthodes
/// sont sans effet : les notifications restent visibles dans l'écran dédié.
/// Linux ne sait pas programmer une notification : les rappels y sont
/// affichés à la synchronisation qui suit leur échéance.
class LocalNotifications {
  final _plugin = FlutterLocalNotificationsPlugin();
  bool _ready = false;
  Future<void>? _initializing;

  static const _details = NotificationDetails(
    android: AndroidNotificationDetails(
      'rappels',
      'Rappels et alertes',
      channelDescription: 'Réservations, rappels de retrait, DLC proche',
      importance: Importance.high,
      priority: Priority.high,
    ),
    iOS: DarwinNotificationDetails(),
    macOS: DarwinNotificationDetails(),
    linux: LinuxNotificationDetails(),
    windows: WindowsNotificationDetails(),
  );

  static const _settings = InitializationSettings(
    android: AndroidInitializationSettings('@mipmap/ic_launcher'),
    iOS: DarwinInitializationSettings(),
    macOS: DarwinInitializationSettings(),
    linux: LinuxInitializationSettings(defaultActionName: 'Ouvrir'),
    windows: WindowsInitializationSettings(
      appName: 'Partage+',
      appUserModelId: 'PartagePlus.RepasPartage',
      guid: '3f6c1a52-8d4e-4b7a-9c21-5e0f7d9a6b13',
    ),
  );

  /// false sur Linux : pas de notification programmée (voir la classe).
  static bool get _canSchedule => defaultTargetPlatform != TargetPlatform.linux;

  /// Types envoyés aussi par le serveur mais déjà programmés localement.
  static const _plannedLocally = {'pickup_reminder', 'expiry_soon'};

  /// Peut être lancé sans attendre : les autres méthodes attendent
  /// la fin de l'initialisation (dont la demande d'autorisation).
  Future<void> init() => _initializing ??= _init();

  /// true une fois init() terminé avec succès.
  Future<bool> _whenReady() async {
    try {
      await _initializing;
    } catch (_) {
      // Échec déjà signalé par l'appelant de init().
    }
    return _ready;
  }

  Future<void> _init() async {
    if (kIsWeb) return;
    tzdata.initializeTimeZones();
    await _plugin.initialize(settings: _settings);
    _ready = true;
    // Pas attendu : les rappels se programment pendant que l'utilisateur
    // répond à la demande d'autorisation.
    unawaited(
      _plugin
          .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin
          >()
          ?.requestNotificationsPermission()
          .catchError((Object error) {
            debugPrint('Autorisation de notification : $error');
            return null;
          }),
    );
  }

  Future<void> show(int id, String title, String body) async {
    if (!await _whenReady()) return;
    await _plugin.show(
      id: id,
      title: title,
      body: body,
      notificationDetails: _details,
    );
  }

  /// Reprogramme les rappels à partir des données locales.
  /// Les rappels dont l'heure est passée sont affichés une seule fois.
  Future<void> reschedule(LocalStore store) async {
    if (!await _whenReady()) return;

    final now = DateTime.now();
    // Réservations et publications faites sans compte comprises : un
    // invité reçoit aussi ses rappels de retrait et alertes de DLC.
    final planned = ReminderPlanner.plan(
      reservations: [
        ...await _list(store, 'reservations'),
        ...await _guestItems(store, 'reservations'),
      ],
      myOffers: [
        ...await _list(store, 'my_offers'),
        ...await _guestItems(store, 'offers'),
      ],
      now: now,
    );
    final plannedIds = planned.map((p) => p.id).toSet();

    // Annule les rappels devenus inutiles (réservation annulée, retirée…).
    for (final request in await _plugin.pendingNotificationRequests()) {
      final ours =
          request.id >= ReminderPlanner.pickupBase &&
          request.id < ReminderPlanner.serverBase;
      if (ours && !plannedIds.contains(request.id)) {
        await _plugin.cancel(id: request.id);
      }
    }

    final delivered = {
      ...?(await store.readSetting<List>('delivered_reminders'))?.cast<int>(),
    };

    for (final notification in planned) {
      if (notification.at.isAfter(now)) {
        if (!_canSchedule) continue;
        await _plugin.zonedSchedule(
          id: notification.id,
          scheduledDate: tz.TZDateTime.from(notification.at, tz.UTC),
          notificationDetails: _details,
          androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
          title: notification.title,
          body: notification.body,
        );
      } else if (delivered.add(notification.id)) {
        await show(notification.id, notification.title, notification.body);
      }
    }

    await store.saveSetting('delivered_reminders', delivered.toList());
  }

  /// Affiche les nouvelles notifications reçues du serveur.
  /// À la première synchronisation, marque tout comme déjà vu.
  Future<void> showNewServerNotifications(LocalStore store) async {
    final notifications = await _list(store, 'notifications');
    if (notifications.isEmpty) return;

    final lastShown = await store.readSetting<int>('last_shown_notification');
    final maxId = notifications
        .map((n) => n['id'] as int)
        .reduce((a, b) => a > b ? a : b);

    if (lastShown != null) {
      for (final notification in notifications.reversed) {
        final id = notification['id'] as int;
        if (id <= lastShown || _plannedLocally.contains(notification['type'])) {
          continue;
        }
        await show(
          ReminderPlanner.serverBase + id % 1000000,
          notification['title'] as String,
          notification['body'] as String,
        );
      }
    }
    await store.saveSetting('last_shown_notification', maxId);
  }

  /// Identifiants des notifications ci-dessous : hors de la plage
  /// annulée par [reschedule].
  static const guestStatusBase = 5000000;
  static const offerAlertBase = 6000000;

  /// Nombre maximal d'alertes « nouvelle offre » affichées une par une.
  static const maxOfferAlerts = 3;

  /// Offres déjà vues par les alertes (gardées au plus).
  static const maxSeenOffers = 2000;

  /// Réservation faite sans compte confirmée ou annulée par le donateur :
  /// l'invité n'a pas de notifications serveur, l'appareil le prévient.
  Future<void> showGuestReservationChanges(LocalStore store) async {
    for (final reservation in await store.readGuestItems('reservations')) {
      final status = reservation['status'];
      final known = reservation['notified_status'];
      if (status == known) continue;
      // Première lecture : rien à signaler, on retient le statut.
      if (known != null) {
        final title = reservation['offer_title'];
        final (heading, body) = switch (status) {
          'confirmed' => (
            'Réservation confirmée',
            '« $title » vous attend. Code de retrait : '
                '${reservation['pickup_code']}.',
          ),
          'cancelled' => (
            'Réservation annulée',
            '« $title » : la réservation a été annulée.',
          ),
          _ => (null, null),
        };
        if (heading != null && body != null) {
          await show(
            guestStatusBase + (reservation['id']! as int) % 1000000,
            heading,
            body,
          );
        }
      }
      await store.patchGuestItem('reservations', reservation['id'], {
        'notified_status': status,
      });
    }
  }

  /// Nouvelles offres qui répondent à une recherche enregistrée (avec ou
  /// sans compte). À la première synchronisation, tout est déjà « vu ».
  Future<void> alertNewOffers(LocalStore store) async {
    final offers = await _list(store, 'offers');
    final ids = [for (final offer in offers) ?offer['id'] as int?];
    final previous = (await store.readSetting<List>(
      'alert_seen_offers',
    ))?.cast<int>();
    await store.saveSetting(
      'alert_seen_offers',
      {...ids, ...?previous}.take(maxSeenOffers).toList(),
    );
    if (previous == null) return;

    final favorites = Favorites.fromMap(await store.readSetting('favorites'));
    if (favorites.searches.isEmpty) return;
    final profile = await store.readSnapshot('profile');
    if (profile is Map) {
      final preferences = profile['preferences'];
      if (preferences is Map && preferences['search_alerts'] == false) return;
    }

    final profileId = profile is Map ? profile['id'] : null;
    final matches = newOfferMatches(
      offers: offers,
      seen: previous.toSet(),
      searches: favorites.searches,
      now: DateTime.now(),
      origin: Place.fromMap(await store.readSetting<Object?>('origin')),
      ownIds: {
        for (final offer in offers)
          if (profileId != null && offer['donor_id'] == profileId)
            ?offer['id'] as int?,
        for (final offer in await store.readGuestItems('offers'))
          ?offer['id'] as int?,
      },
    );

    for (final (offer, search) in matches.take(maxOfferAlerts)) {
      await show(
        offerAlertBase + (offer['id']! as int) % 1000000,
        'Nouvelle offre · ${search.name}',
        '« ${offer['title']} » correspond à votre recherche.',
      );
    }
    if (matches.length > maxOfferAlerts) {
      await show(
        offerAlertBase + 999999,
        'Nouvelles offres pour vos recherches',
        '${matches.length - maxOfferAlerts} autre(s) offre(s) correspondent '
            'à vos recherches enregistrées.',
      );
    }
  }

  Future<List<Map<String, dynamic>>> _guestItems(
    LocalStore store,
    String kind,
  ) async => [
    for (final item in await store.readGuestItems(kind))
      item.cast<String, dynamic>(),
  ];

  Future<List<Map<String, dynamic>>> _list(LocalStore store, String key) async {
    final value = await store.readSnapshot(key);
    return value is List
        ? value.cast<Map>().map((m) => m.cast<String, dynamic>()).toList()
        : const [];
  }
}

/// Remplacé dans main() par une instance initialisée.
final localNotificationsProvider = Provider<LocalNotifications>(
  (ref) => LocalNotifications(),
);
