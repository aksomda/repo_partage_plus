import 'package:flutter/material.dart';

import 'package:repo_partage_plus/core/network/api_config.dart';
import 'package:repo_partage_plus/core/offline/offline_data.dart';
import 'package:repo_partage_plus/core/theme/app_theme.dart';

// ---------- Formats (français, sans dépendance) ----------

/// 1500 → « 1 500 F CFA » ; 0 → « Gratuit ».
String formatPrice(num? value) {
  final price = (value ?? 0).round();
  if (price == 0) return 'Gratuit';
  return '${formatNumber(price)} F CFA';
}

/// Nombre à la française : 1234.5 → « 1 234,5 ». Les décimales nulles
/// sont retirées (12.0 → « 12 »).
String formatNumber(num? value, {int decimals = 0}) {
  final fixed = (value ?? 0).toDouble().toStringAsFixed(decimals);
  final negative = fixed.startsWith('-');
  final parts = (negative ? fixed.substring(1) : fixed).split('.');
  final digits = parts[0];
  final buffer = StringBuffer(negative ? '-' : '');
  for (var i = 0; i < digits.length; i++) {
    if (i > 0 && (digits.length - i) % 3 == 0) buffer.write(' ');
    buffer.write(digits[i]);
  }
  final fraction = parts.length > 1
      ? parts[1].replaceAll(RegExp(r'0+$'), '')
      : '';
  if (fraction.isNotEmpty) buffer.write(',$fraction');
  return buffer.toString();
}

String formatDistance(num? km) {
  if (km == null) return '';
  if (km < 1) return '${(km * 1000).round()} m';
  return '${km.toStringAsFixed(km < 10 ? 1 : 0).replaceAll('.', ',')} km';
}

String _two(int value) => value.toString().padLeft(2, '0');

/// « aujourd'hui », « demain », sinon « 12/10 ».
String formatDay(DateTime date) {
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  final day = DateTime(date.year, date.month, date.day);
  final diff = day.difference(today).inDays;
  if (diff == 0) return 'aujourd’hui';
  if (diff == 1) return 'demain';
  if (diff == -1) return 'hier';
  return '${_two(date.day)}/${_two(date.month)}';
}

String formatHour(DateTime date) => '${_two(date.hour)}h${_two(date.minute)}';

/// « aujourd'hui 16h00 – 20h00 » (heure locale).
String formatPickup(Json offer) {
  final start = DateTime.parse(offer['pickup_start'] as String).toLocal();
  final end = DateTime.parse(offer['pickup_end'] as String).toLocal();
  final sameDay =
      start.year == end.year &&
      start.month == end.month &&
      start.day == end.day;
  return sameDay
      ? '${formatDay(start)} ${formatHour(start)} – ${formatHour(end)}'
      : '${formatDay(start)} ${formatHour(start)} – ${formatDay(end)} ${formatHour(end)}';
}

String formatExpiry(Json offer) =>
    'Exp. : ${formatDay(DateTime.parse(offer['expiry_date'] as String))}';

// ---------- Catégories ----------

const _categoryIcons = <String, IconData>{
  'eco': Icons.eco_outlined,
  'bakery_dining': Icons.bakery_dining_outlined,
  'restaurant': Icons.restaurant,
  'egg': Icons.egg_outlined,
  'shopping_basket': Icons.shopping_basket_outlined,
  'local_drink': Icons.local_drink_outlined,
};

IconData categoryIcon(Object? name) =>
    _categoryIcons[name] ?? Icons.fastfood_outlined;

/// Couleur de fond associée à une catégorie (déterministe).
Color categoryColor(Object? id) {
  const palette = [
    Color(0xFFE6F3EA),
    Color(0xFFFDEFD9),
    Color(0xFFFDE7E7),
    Color(0xFFE8EEFB),
    Color(0xFFF3E8FB),
    Color(0xFFE5F6F6),
  ];
  return palette[(id is int ? id : 0) % palette.length];
}

/// URL de la photo de l'offre, ou null si elle n'en a pas.
String? offerPhotoUrl(Json offer) {
  final path = offer['photo_path'] as String?;
  return path == null ? null : '${ApiConfig.baseUrl}$path';
}

/// Photo de l'offre ; sans photo (ou hors ligne), pictogramme de la catégorie.
class OfferPhoto extends StatelessWidget {
  const OfferPhoto({
    super.key,
    required this.offer,
    required this.iconSize,
    this.width,
    this.height,
  });

  final Json offer;
  final double iconSize;
  final double? width;
  final double? height;

  @override
  Widget build(BuildContext context) {
    final placeholder = Container(
      width: width,
      height: height,
      color: categoryColor(offer['category_id']),
      child: Icon(
        categoryIcon(offer['category_icon']),
        size: iconSize,
        color: AppColors.primary,
      ),
    );
    final url = offerPhotoUrl(offer);
    if (url == null) return placeholder;
    return Image.network(
      url,
      width: width,
      height: height,
      fit: BoxFit.cover,
      errorBuilder: (_, _, _) => placeholder,
      loadingBuilder: (_, child, progress) =>
          progress == null ? child : placeholder,
    );
  }
}

/// Vignette de l'offre : sa photo, ou le pictogramme de la catégorie.
class OfferThumbnail extends StatelessWidget {
  const OfferThumbnail({super.key, required this.offer, this.size = 72});

  final Json offer;
  final double size;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(AppTheme.radius),
      child: OfferPhoto(
        offer: offer,
        width: size,
        height: size,
        iconSize: size * 0.45,
      ),
    );
  }
}

/// Carte d'offre des listes (accueil, recherche, carte).
class OfferCard extends StatelessWidget {
  const OfferCard({super.key, required this.offer, required this.onTap});

  final Json offer;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final price = offer['price'] as num? ?? 0;
    final distance = offer['distance_km'] as num?;

    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              OfferThumbnail(offer: offer),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      offer['title'] as String,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontWeight: FontWeight.w700,
                        fontSize: 15,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      offer['donor_name'] as String? ?? '',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: AppColors.textMuted,
                        fontSize: 13,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Wrap(
                      spacing: 10,
                      runSpacing: 2,
                      children: [
                        if (distance != null)
                          _Info(Icons.place_outlined, formatDistance(distance)),
                        _Info(
                          Icons.sell_outlined,
                          formatPrice(price),
                          color: price == 0
                              ? AppColors.primary
                              : AppColors.accent,
                        ),
                        _Info(
                          Icons.schedule,
                          formatExpiry(offer),
                          color: AppColors.accent,
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Info extends StatelessWidget {
  const _Info(this.icon, this.text, {this.color = AppColors.textMuted});

  final IconData icon;
  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 14, color: color),
        const SizedBox(width: 3),
        Text(
          text,
          style: TextStyle(
            color: color,
            fontSize: 12,
            fontWeight: FontWeight.w600,
          ),
        ),
      ],
    );
  }
}

/// Pastille de statut d'une offre ou d'une réservation.
class StatusBadge extends StatelessWidget {
  const StatusBadge(this.status, {super.key});

  final String status;

  static const _labels = {
    'pending': ('En attente', AppColors.accentSoft, AppColors.accent),
    'published': ('Publiée', AppColors.primarySoft, AppColors.primary),
    'reserved': ('Tout réservé', AppColors.primarySoft, AppColors.primary),
    'completed': ('Terminée', AppColors.primarySoft, AppColors.primary),
    'confirmed': ('Confirmée', AppColors.primarySoft, AppColors.primary),
    'picked_up': ('Retirée', AppColors.primarySoft, AppColors.primary),
    'rejected': ('Refusée', Color(0xFFFDE7E7), AppColors.danger),
    'cancelled': ('Annulée', Color(0xFFFDE7E7), AppColors.danger),
    'expired': ('Expirée', Color(0xFFFDE7E7), AppColors.danger),
    'unavailable': ('Indisponible', Color(0xFFFDE7E7), AppColors.danger),
    'pending_sync': (
      'En attente d’envoi',
      AppColors.accentSoft,
      AppColors.accent,
    ),
  };

  @override
  Widget build(BuildContext context) {
    final (label, background, foreground) =
        _labels[status] ?? (status, AppColors.border, AppColors.text);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: ShapeDecoration(
        color: background,
        shape: const StadiumBorder(),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: foreground,
          fontSize: 11,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

/// Message centré pour les listes vides ou en erreur.
class EmptyState extends StatelessWidget {
  const EmptyState({
    super.key,
    required this.icon,
    required this.title,
    this.message,
    this.action,
  });

  final IconData icon;
  final String title;
  final String? message;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 72,
            height: 72,
            decoration: const BoxDecoration(
              color: AppColors.primarySoft,
              shape: BoxShape.circle,
            ),
            child: Icon(icon, size: 36, color: AppColors.primary),
          ),
          const SizedBox(height: 16),
          Text(
            title,
            textAlign: TextAlign.center,
            style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16),
          ),
          if (message != null) ...[
            const SizedBox(height: 6),
            Text(
              message!,
              textAlign: TextAlign.center,
              style: const TextStyle(color: AppColors.textMuted),
            ),
          ],
          if (action != null) ...[const SizedBox(height: 16), action!],
        ],
      ),
    );
  }
}
