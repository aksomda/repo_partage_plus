abstract final class ApiConfig {
  /// API hébergée sur Render (base TiDB), utilisée par défaut.
  static const renderUrl = 'https://repo-partage-plus.onrender.com/api';

  /// Autre URL, injectée au lancement ou au build, par ex. le serveur local :
  /// `flutter run -d chrome --dart-define=API_BASE_URL=http://localhost:3000/api`
  /// (émulateur Android : `http://10.0.2.2:3000/api`).
  static const _fromEnvironment = String.fromEnvironment('API_BASE_URL');

  static String get baseUrl =>
      _fromEnvironment.isNotEmpty ? _fromEnvironment : renderUrl;
}
