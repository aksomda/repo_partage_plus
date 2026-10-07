import 'package:flutter/material.dart';

import 'package:repo_partage_plus/core/network/api_config.dart';
import 'package:repo_partage_plus/core/offline/offline_data.dart';
import 'package:repo_partage_plus/core/theme/app_theme.dart';

/// Initiales du prénom et du nom (« Awa Traoré » → « AT »).
String profileInitials(String name) {
  final parts = name.split(RegExp(r'\s+')).where((p) => p.isNotEmpty).toList();
  if (parts.isEmpty) return '?';
  if (parts.length == 1) return parts.first[0].toUpperCase();
  return '${parts.first[0]}${parts.last[0]}'.toUpperCase();
}

/// URL de la photo de profil du compte (null : pas de photo).
String? profilePhotoUrl(Json? user) {
  final path = user?['photo_path'] as String?;
  return path == null ? null : '${ApiConfig.baseUrl}$path';
}

/// Pastille ronde du compte (en-têtes, profil) : sa photo, sinon ses
/// initiales (aussi hors ligne ou si la photo ne se charge pas).
class ProfileAvatar extends StatelessWidget {
  const ProfileAvatar({
    super.key,
    required this.name,
    this.size = 36,
    this.photoUrl,
  });

  final String name;
  final double size;
  final String? photoUrl;

  @override
  Widget build(BuildContext context) {
    final initials = Text(
      profileInitials(name.trim()),
      style: TextStyle(
        color: Colors.white,
        fontSize: size * 0.36,
        fontWeight: FontWeight.w800,
      ),
    );
    final url = photoUrl;
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: AppColors.accent,
        shape: BoxShape.circle,
        border: Border.all(color: Colors.white, width: size / 18),
        boxShadow: const [BoxShadow(color: Colors.black12, blurRadius: 4)],
      ),
      child: url == null
          ? initials
          : Image.network(
              url,
              width: size,
              height: size,
              fit: BoxFit.cover,
              errorBuilder: (_, _, _) => Center(child: initials),
            ),
    );
  }
}
