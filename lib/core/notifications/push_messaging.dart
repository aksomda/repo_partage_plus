import 'dart:async';

import 'package:dio/dio.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:repo_partage_plus/core/firebase/firebase_init.dart';
import 'package:repo_partage_plus/core/network/api_client.dart';
import 'package:repo_partage_plus/core/network/api_endpoints.dart';
import 'package:repo_partage_plus/core/notifications/local_notifications.dart';
import 'package:repo_partage_plus/core/offline/sync_controller.dart';
import 'package:repo_partage_plus/core/router/app_router.dart';
import 'package:repo_partage_plus/features/notifications/data/chat_repository.dart';

/// Code reçu par push (activation du compte ou mot de passe oublié).
typedef PushedCode = ({String purpose, String code});

/// Notifications push (Firebase Cloud Messaging), Android et iOS : le
/// jeton de l'appareil est enregistré sur le serveur tant qu'un compte est
/// connecté. Application ouverte, un push déclenche une synchronisation (la
/// notification s'affiche alors comme les autres) ; touché, il ouvre l'écran
/// concerné. Sans Firebase, ou sur les autres plateformes : sans effet.
class PushMessaging {
  PushMessaging(this._ref);

  final Ref _ref;
  String? _registeredToken;
  final _subscriptions = <StreamSubscription<Object?>>[];
  final _codes = StreamController<PushedCode>.broadcast();

  /// Codes reçus par push : les écrans de saisie du code se remplissent seuls.
  Stream<PushedCode> get codes => _codes.stream;

  static bool get supported =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.iOS);

  Future<FirebaseMessaging?> _messaging() async {
    if (!supported) return null;
    await ensureFirebase();
    try {
      return FirebaseMessaging.instance;
    } catch (error) {
      debugPrint('Push indisponible : $error');
      return null;
    }
  }

  /// Écoute les messages et les touchers (une fois, au démarrage).
  Future<void> start() async {
    final messaging = await _messaging();
    if (messaging == null) return;
    try {
      _subscriptions
        ..add(
          FirebaseMessaging.onMessage.listen((message) {
            if (_takeCode(message, showNotification: true)) return;
            _ref.read(syncControllerProvider.notifier).syncNow();
          }),
        )
        ..add(FirebaseMessaging.onMessageOpenedApp.listen(_open))
        ..add(messaging.onTokenRefresh.listen(_send));
      final initial = await messaging.getInitialMessage();
      if (initial != null) _open(initial);
    } catch (error) {
      debugPrint('Push indisponible : $error');
    }
  }

  /// Code d'activation ou de mot de passe oublié : transmis à l'écran de
  /// saisie. Application ouverte, Android n'affiche pas la notification :
  /// elle est alors montrée par l'application.
  bool _takeCode(RemoteMessage message, {bool showNotification = false}) {
    final code = message.data['code'];
    if (message.data['type'] != 'otp_code' || code is! String) return false;
    _codes.add((purpose: '${message.data['purpose']}', code: code));
    final notification = message.notification;
    if (showNotification && notification != null) {
      unawaited(
        _ref
            .read(localNotificationsProvider)
            .show(
              900000 + int.parse(code) % 1000,
              notification.title ?? 'Code Partage+',
              notification.body ?? '',
            ),
      );
    }
    return true;
  }

  void _open(RemoteMessage message) {
    if (_takeCode(message)) return;
    final link = notificationLink({
      'type': message.data['type'],
      'data': message.data.map(
        (key, value) => MapEntry(key, int.tryParse('$value') ?? value),
      ),
    });
    _ref.read(syncControllerProvider.notifier).syncNow();
    if (link != null) _ref.read(routerProvider).push(link);
  }

  /// Jeton de l'appareil, envoyé avec l'inscription (le compte n'est pas
  /// encore connecté) pour recevoir aussi le code d'activation par push.
  /// null si le push n'est pas disponible ; jamais bloquant.
  Future<Map<String, String>?> signupDevice() async {
    final messaging = await _messaging();
    if (messaging == null) return null;
    try {
      await messaging.requestPermission();
      final token = await messaging.getToken().timeout(
        const Duration(seconds: 5),
      );
      if (token == null) return null;
      return {
        'device_token': token,
        'device_platform': defaultTargetPlatform == TargetPlatform.iOS
            ? 'ios'
            : 'android',
      };
    } catch (error) {
      debugPrint('Jeton push indisponible : $error');
      return null;
    }
  }

  /// Compte connecté : autorisation demandée, jeton envoyé au serveur.
  Future<void> register() async {
    final messaging = await _messaging();
    if (messaging == null) return;
    try {
      await messaging.requestPermission();
      final token = await messaging.getToken();
      if (token != null) await _send(token);
    } catch (error) {
      debugPrint('Jeton push non enregistré : $error');
    }
  }

  Future<void> _send(String token) async {
    if (_ref.read(authTokenProvider) == null) return;
    try {
      await _ref
          .read(dioProvider)
          .post<void>(
            ApiEndpoints.devices,
            data: {
              'token': token,
              'platform': defaultTargetPlatform == TargetPlatform.iOS
                  ? 'ios'
                  : 'android',
            },
          );
      _registeredToken = token;
    } on DioException catch (error) {
      // Hors ligne : renvoyé à la prochaine ouverture de session.
      debugPrint('Jeton push non enregistré : ${error.message}');
    }
  }

  /// Avant la déconnexion : l'appareil ne reçoit plus les push du compte.
  Future<void> unregister() async {
    final token = _registeredToken;
    if (token == null) return;
    _registeredToken = null;
    try {
      await _ref
          .read(dioProvider)
          .delete<void>(ApiEndpoints.devices, data: {'token': token});
    } on DioException catch (error) {
      debugPrint('Jeton push non retiré : ${error.message}');
    }
  }

  void dispose() {
    _codes.close();
    for (final subscription in _subscriptions) {
      subscription.cancel();
    }
  }
}

/// Démarré par l'application ; enregistre le jeton à chaque connexion.
final pushMessagingProvider = Provider<PushMessaging>((ref) {
  final push = PushMessaging(ref);
  ref.onDispose(push.dispose);
  unawaited(push.start());
  ref.listen<String?>(authTokenProvider, (previous, next) {
    if (next != null && next != previous) unawaited(push.register());
  }, fireImmediately: true);
  return push;
});
