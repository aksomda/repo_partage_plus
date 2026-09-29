import 'package:flutter/foundation.dart';

abstract final class ApiConfig {
  /// URL de l'API, injectée au build :
  /// `flutter build apk --dart-define=API_BASE_URL=https://mon-api.onrender.com/api`
  static const _fromEnvironment = String.fromEnvironment('API_BASE_URL');

  static String get baseUrl {
    if (_fromEnvironment.isNotEmpty) return _fromEnvironment;
    // En local, l'émulateur Android voit la machine hôte via 10.0.2.2.
    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
      return 'http://10.0.2.2:3000/api';
    }
    return 'http://localhost:3000/api';
  }
}
