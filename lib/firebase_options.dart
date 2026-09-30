// Configuration Firebase du projet partageplus-f8840 pour Android, iOS et le
// web (générée par « flutterfire configure », qui peut régénérer ce fichier).
// macOS et Windows ne sont pas configurés : Firebase y est indisponible et
// l'application fonctionne sans.
//
// Ces clés identifient l'application auprès de Firebase ; elles ne sont pas
// secrètes (la sécurité repose sur les règles et App Check).

import 'package:firebase_core/firebase_core.dart' show FirebaseOptions;
import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, kIsWeb, TargetPlatform;

class DefaultFirebaseOptions {
  static FirebaseOptions get currentPlatform {
    if (kIsWeb) {
      return web;
    }
    return switch (defaultTargetPlatform) {
      TargetPlatform.android => android,
      TargetPlatform.iOS => ios,
      _ => throw UnsupportedError(
        'Firebase non configuré pour $defaultTargetPlatform : '
        'lancer « flutterfire configure »',
      ),
    };
  }

  static const FirebaseOptions android = FirebaseOptions(
    apiKey: 'AIzaSyDbLyFBXOx_6OeB15tWCUgokKVTcNZge4o',
    appId: '1:179535500663:android:26d5ab83103c141932fd72',
    messagingSenderId: '179535500663',
    projectId: 'partageplus-f8840',
    storageBucket: 'partageplus-f8840.firebasestorage.app',
  );
  static const FirebaseOptions ios = FirebaseOptions(
    apiKey: 'AIzaSyBBJtVih_0Cnccjp_chGd-SguByHQQwpg0',
    appId: '1:179535500663:ios:b56f8e04dbe8fc8c32fd72',
    messagingSenderId: '179535500663',
    projectId: 'partageplus-f8840',
    storageBucket: 'partageplus-f8840.firebasestorage.app',
    iosClientId:
        '179535500663-a17f0290p8t2k4c19cm0atdcpg0678qp.apps.googleusercontent.com',
    iosBundleId: 'com.example.repoPartagePlus',
  );
  static const FirebaseOptions web = FirebaseOptions(
    apiKey: 'AIzaSyC0c-eWpRMe-82Xv23sw_oWGkb-R9BrQ2M',
    appId: '1:179535500663:web:30b3c8552d8df13932fd72',
    messagingSenderId: '179535500663',
    projectId: 'partageplus-f8840',
    authDomain: 'partageplus-f8840.firebaseapp.com',
    storageBucket: 'partageplus-f8840.firebasestorage.app',
    measurementId: 'G-BDJSGMFDF8',
  );
}
