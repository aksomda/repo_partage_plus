import 'package:repo_partage_plus/core/offline/offline_data.dart';

/// Tableau d'impact au format CSV (séparateur « ; », comme Excel en
/// français) : totaux, indicateurs sociaux, évolution mensuelle et
/// répartition par catégorie. [impact] : totaux ; [social] : indicateurs
/// sociaux (clé → valeur) ; [monthly] et [byCategory] : lignes du serveur.
String impactCsv({
  required String title,
  required Json impact,
  Json social = const {},
  List<Json> monthly = const [],
  List<Json> byCategory = const [],
  Map<String, String> socialLabels = const {},
}) {
  final rows = <List<Object?>>[
    [title],
    [],
    ['Indicateur', 'Valeur'],
    ['Retraits', impact['pickups']],
    ['Produits sauvés', impact['items']],
    ['Nourriture sauvée (kg)', _decimal(impact['food_kg'])],
    ['CO2 évité (kg)', _decimal(impact['co2_kg'])],
    ['Repas équivalents', impact['meals']],
    if (impact['users'] != null) ['Utilisateurs actifs', impact['users']],
    for (final entry in social.entries)
      [socialLabels[entry.key] ?? entry.key, entry.value],
    if (monthly.isNotEmpty) ...[
      [],
      ['Mois', 'Retraits', 'Nourriture (kg)', 'CO2 (kg)', 'Repas'],
      for (final month in monthly)
        [
          month['month'],
          month['pickups'],
          _decimal(month['food_kg']),
          _decimal(month['co2_kg']),
          month['meals'],
        ],
    ],
    if (byCategory.isNotEmpty) ...[
      [],
      ['Catégorie', 'Retraits', 'Nourriture (kg)', 'CO2 (kg)', 'Repas'],
      for (final category in byCategory)
        [
          category['category_name'],
          category['pickups'],
          _decimal(category['food_kg']),
          _decimal(category['co2_kg']),
          category['meals'],
        ],
    ],
  ];
  return rows.map((row) => row.map(_cell).join(';')).join('\r\n');
}

/// Nombre décimal avec virgule (Excel en français).
String _decimal(Object? value) =>
    value is num ? value.toString().replaceAll('.', ',') : '';

String _cell(Object? value) {
  final text = value?.toString() ?? '';
  if (!text.contains(RegExp('[;"\r\n]'))) return text;
  return '"${text.replaceAll('"', '""')}"';
}
