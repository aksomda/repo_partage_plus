import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

import 'package:repo_partage_plus/core/notifications/reminder_planner.dart';
import 'package:repo_partage_plus/core/storage/local_store.dart';

/// Notifications affichées par l'appareil (Android/iOS).
///
/// Sur le web, ou si init() n'a pas été appelé (tests), toutes les méthodes
/// sont sans effet : les notifications restent visibles dans l'écran dédié.
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
  );

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
    await _plugin.initialize(
      settings: const InitializationSettings(
        android: AndroidInitializationSettings('@mipmap/ic_launcher'),
        iOS: DarwinInitializationSettings(),
      ),
    );
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
    final planned = ReminderPlanner.plan(
      reservations: await _list(store, 'reservations'),
      myOffers: await _list(store, 'my_offers'),
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
