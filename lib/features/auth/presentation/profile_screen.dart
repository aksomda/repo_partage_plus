import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:repo_partage_plus/core/offline/sync_controller.dart';
import 'package:repo_partage_plus/features/auth/data/auth_repository.dart';
import 'package:repo_partage_plus/features/auth/data/profile_repository.dart';
import 'package:repo_partage_plus/features/offers/data/offers_repository.dart';
import 'package:repo_partage_plus/features/recommendations/data/preferences.dart';

typedef Json = Map<String, dynamic>;

class ProfileScreen extends ConsumerStatefulWidget {
  const ProfileScreen({super.key});

  @override
  ConsumerState<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends ConsumerState<ProfileScreen> {
  final _formKey = GlobalKey<FormState>();
  final _nameController = TextEditingController();
  final _phoneController = TextEditingController();

  bool _editing = false;
  bool _saving = false;
  bool _pushNotifications = true;
  bool _favoriteAlerts = true;
  bool _offlineMode = true;
  bool _emailSummary = false;
  String? _loadedProfileId;

  static const _green = Color(0xFF218B45);
  static const _lightGreen = Color(0xFFE9F5EC);
  static const _pageBackground = Color(0xFFF5F7F3);
  static const _border = Color(0xFFDCE3DB);
  static const _text = Color(0xFF26322A);
  static const _muted = Color(0xFF738078);
  static const _danger = Color(0xFFC94A42);

  @override
  void dispose() {
    _nameController.dispose();
    _phoneController.dispose();
    super.dispose();
  }

  void _hydrate(Json profile) {
    final id = '${profile['id'] ?? profile['email'] ?? ''}';
    if (_loadedProfileId == id) return;

    _loadedProfileId = id;

    final first = '${profile['first_name'] ?? ''}'.trim();
    final last = '${profile['last_name'] ?? ''}'.trim();
    final fallbackName = '${profile['name'] ?? ''}'.trim();

    _nameController.text =
        [first, last].where((v) => v.isNotEmpty).join(' ').trim();

    if (_nameController.text.isEmpty) {
      _nameController.text = fallbackName;
    }

    _phoneController.text = '${profile['phone'] ?? ''}';
  }

  String _roleLabel(String? role) {
    switch (role) {
      case 'beneficiary':
        return 'Bénéficiaire';
      case 'donor':
        return 'Donateur';
      case 'association':
        return 'Association';
      case 'admin':
        return 'Administrateur';
      default:
        return 'Utilisateur';
    }
  }

  String _statusLabel(String? status) {
    switch (status) {
      case 'active':
        return 'Compte actif';
      case 'pending':
        return 'Compte en attente';
      case 'suspended':
        return 'Compte suspendu';
      default:
        return 'Membre';
    }
  }

  Future<void> _saveProfile(Json profile) async {
    if (!_formKey.currentState!.validate()) return;

    setState(() => _saving = true);

    try {
      final result = await ref.read(profileRepositoryProvider).updateProfile(
            name: _nameController.text.trim(),
            phone: _phoneController.text.trim(),
            latitude: (profile['latitude'] as num?)?.toDouble(),
            longitude: (profile['longitude'] as num?)?.toDouble(),
          );

      if (!mounted) return;

      final message = result is Queued
          ? 'Modification enregistrée hors ligne.'
          : result is Rejected
              ? 'Modification refusée : ${result.message}'
              : 'Profil mis à jour.';

      setState(() => _editing = false);

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(message)),
      );
    } catch (error) {
      if (!mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Impossible de modifier le profil : $error'),
        ),
      );
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _showEditProfile(Json profile) async {
    setState(() => _editing = true);
  }

  Future<void> _showPasswordDialog() async {
    final formKey = GlobalKey<FormState>();
    final current = TextEditingController();
    final next = TextEditingController();
    final confirm = TextEditingController();

    try {
      await showDialog<void>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('Modifier le mot de passe'),
          content: Form(
            key: formKey,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextFormField(
                    controller: current,
                    obscureText: true,
                    decoration: const InputDecoration(
                      labelText: 'Mot de passe actuel',
                    ),
                    validator: (value) =>
                        value == null || value.isEmpty ? 'Champ requis' : null,
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: next,
                    obscureText: true,
                    decoration: const InputDecoration(
                      labelText: 'Nouveau mot de passe',
                    ),
                    validator: (value) => value == null || value.length < 8
                        ? '8 caractères minimum'
                        : null,
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: confirm,
                    obscureText: true,
                    decoration: const InputDecoration(
                      labelText: 'Confirmation',
                    ),
                    validator: (value) =>
                        value != next.text ? 'Les mots de passe diffèrent' : null,
                  ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('Annuler'),
            ),
            FilledButton(
              onPressed: () async {
                if (!formKey.currentState!.validate()) return;

                try {
                  final result =
                      await ref.read(profileRepositoryProvider).changePassword(
                            currentPassword: current.text,
                            newPassword: next.text,
                          );

                  if (!mounted) return;

                  Navigator.pop(dialogContext);

                  final message = result is Queued
                      ? 'Changement mis en attente de synchronisation.'
                      : result is Rejected
                          ? 'Changement refusé : ${result.message}'
                          : 'Mot de passe modifié.';

                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text(message)),
                  );
                } catch (error) {
                  ScaffoldMessenger.of(dialogContext).showSnackBar(
                    SnackBar(content: Text('$error')),
                  );
                }
              },
              child: const Text('Enregistrer'),
            ),
          ],
        ),
      );
    } finally {
      current.dispose();
      next.dispose();
      confirm.dispose();
    }
  }

  Future<void> _logout() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Déconnexion'),
        content: const Text('Voulez-vous vraiment vous déconnecter ?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Annuler'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Se déconnecter'),
          ),
        ],
      ),
    );

    if (confirmed != true || !mounted) return;

    await ref.read(authRepositoryProvider).logout();
  }

  @override
  Widget build(BuildContext context) {
    final profile = ref.watch(profileProvider);

    if (profile == null) {
      return Scaffold(
        backgroundColor: _pageBackground,
        appBar: AppBar(
          title: const Text('Profil'),
          backgroundColor: _pageBackground,
        ),
        body: const Center(
          child: Padding(
            padding: EdgeInsets.all(24),
            child: Text(
              'Aucun profil local disponible.\n'
              'Connectez-vous à Internet pour récupérer votre profil.',
              textAlign: TextAlign.center,
            ),
          ),
        ),
      );
    }

    _hydrate(profile);

    final role = profile['role'] as String?;
    final roleLabel = _roleLabel(role);
    final name = _displayName(profile);
    final initials = _initials(name);
    final memberSince = _memberSince(profile);

    final association = profile['association'] is Map
        ? Map<String, dynamic>.from(profile['association'] as Map)
        : null;

    return Scaffold(
      backgroundColor: _pageBackground,
      body: SafeArea(
        bottom: false,
        child: CustomScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          slivers: [
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(14, 10, 14, 0),
              sliver: SliverToBoxAdapter(
                child: _ProfileTopBar(
                  name: name,
                  initials: initials,
                  role: roleLabel,
                  memberSince: memberSince,
                  editing: _editing,
                  onEdit: () => _showEditProfile(profile),
                ),
              ),
            ),
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(14, 10, 14, 0),
              sliver: SliverToBoxAdapter(
                child: _editing
                    ? _EditProfileCard(
                        formKey: _formKey,
                        nameController: _nameController,
                        phoneController: _phoneController,
                        email: '${profile['email'] ?? '—'}',
                        saving: _saving,
                        onCancel: () => setState(() => _editing = false),
                        onSave: () => _saveProfile(profile),
                      )
                    : _AccountSummary(
                        email: '${profile['email'] ?? '—'}',
                        phone: '${profile['phone'] ?? '—'}',
                        status: _statusLabel(profile['status'] as String?),
                      ),
              ),
            ),
            if (role == 'beneficiary')
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(14, 10, 14, 0),
                sliver: SliverToBoxAdapter(
                  child: _PreferencesSection(),
                ),
              ),
            if (role == 'association' && association != null)
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(14, 10, 14, 0),
                sliver: SliverToBoxAdapter(
                  child: _AssociationSection(association: association),
                ),
              ),
            if (role != 'beneficiary' && role != 'association')
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(14, 10, 14, 0),
                sliver: SliverToBoxAdapter(
                  child: _RoleSection(
                    role: roleLabel,
                    actorLabel: profile['actor_label'] as String?,
                    status: _statusLabel(profile['status'] as String?),
                  ),
                ),
              ),
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(14, 10, 14, 0),
              sliver: SliverToBoxAdapter(
                child: _NotificationsSection(
                  pushNotifications: _pushNotifications,
                  favoriteAlerts: _favoriteAlerts,
                  offlineMode: _offlineMode,
                  emailSummary: _emailSummary,
                  onPushChanged: (value) =>
                      setState(() => _pushNotifications = value),
                  onFavoritesChanged: (value) =>
                      setState(() => _favoriteAlerts = value),
                  onOfflineChanged: (value) =>
                      setState(() => _offlineMode = value),
                  onEmailChanged: (value) =>
                      setState(() => _emailSummary = value),
                ),
              ),
            ),
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(14, 10, 14, 0),
              sliver: SliverToBoxAdapter(
                child: _MenuSection(
                  onPassword: _showPasswordDialog,
                ),
              ),
            ),
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(14, 10, 14, 26),
              sliver: SliverToBoxAdapter(
                child: _LogoutButton(onPressed: _logout),
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _displayName(Json profile) {
    final first = '${profile['first_name'] ?? ''}'.trim();
    final last = '${profile['last_name'] ?? ''}'.trim();
    final full = [first, last].where((v) => v.isNotEmpty).join(' ').trim();

    if (full.isNotEmpty) return full;

    final name = '${profile['name'] ?? ''}'.trim();
    return name.isEmpty ? 'Utilisateur' : name;
  }

  String _initials(String name) {
    final parts =
        name.split(RegExp(r'\s+')).where((value) => value.isNotEmpty).toList();

    if (parts.isEmpty) return 'U';
    if (parts.length == 1) {
      return parts.first.substring(0, 1).toUpperCase();
    }

    return '${parts.first[0]}${parts.last[0]}'.toUpperCase();
  }

  String _memberSince(Json profile) {
    final raw = profile['created_at'] ?? profile['createdAt'];

    if (raw == null) return 'Membre de Partage+';

    final date = DateTime.tryParse('$raw');
    if (date == null) return 'Membre de Partage+';

    const months = [
      'janvier',
      'février',
      'mars',
      'avril',
      'mai',
      'juin',
      'juillet',
      'août',
      'septembre',
      'octobre',
      'novembre',
      'décembre',
    ];

    return 'Membre depuis ${months[date.month - 1]} ${date.year}';
  }
}

class _ProfileTopBar extends StatelessWidget {
  const _ProfileTopBar({
    required this.name,
    required this.initials,
    required this.role,
    required this.memberSince,
    required this.editing,
    required this.onEdit,
  });

  final String name;
  final String initials;
  final String role;
  final String memberSince;
  final bool editing;
  final VoidCallback onEdit;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Container(
          width: 50,
          height: 50,
          decoration: BoxDecoration(
            color: const Color(0xFFFF9817),
            borderRadius: BorderRadius.circular(14),
          ),
          alignment: Alignment.center,
          child: Text(
            initials,
            style: const TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.w800,
              fontSize: 17,
            ),
          ),
        ),
        const SizedBox(width: 11),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: _ProfileScreenState._text,
                  fontSize: 16,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                memberSince,
                style: const TextStyle(
                  color: _ProfileScreenState._muted,
                  fontSize: 10.5,
                ),
              ),
              const SizedBox(height: 4),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: const Color(0xFFFFE9C9),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text(
                  role,
                  style: const TextStyle(
                    color: Color(0xFF9A641B),
                    fontSize: 9.5,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(width: 8),
        Material(
          color: Colors.white,
          borderRadius: BorderRadius.circular(12),
          child: InkWell(
            borderRadius: BorderRadius.circular(12),
            onTap: onEdit,
            child: const SizedBox(
              width: 42,
              height: 42,
              child: Icon(
                Icons.edit_outlined,
                size: 19,
                color: _ProfileScreenState._text,
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _AccountSummary extends StatelessWidget {
  const _AccountSummary({
    required this.email,
    required this.phone,
    required this.status,
  });

  final String email;
  final String phone;
  final String status;

  @override
  Widget build(BuildContext context) {
    return _ProfileCard(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      child: Row(
        children: [
          const Icon(Icons.verified_user_outlined,
              size: 18, color: _ProfileScreenState._green),
          const SizedBox(width: 9),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  status,
                  style: const TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    color: _ProfileScreenState._text,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  email,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 10,
                    color: _ProfileScreenState._muted,
                  ),
                ),
              ],
            ),
          ),
          if (phone.isNotEmpty && phone != '—')
            Text(
              phone,
              style: const TextStyle(
                fontSize: 10,
                color: _ProfileScreenState._muted,
              ),
            ),
        ],
      ),
    );
  }
}

class _EditProfileCard extends StatelessWidget {
  const _EditProfileCard({
    required this.formKey,
    required this.nameController,
    required this.phoneController,
    required this.email,
    required this.saving,
    required this.onCancel,
    required this.onSave,
  });

  final GlobalKey<FormState> formKey;
  final TextEditingController nameController;
  final TextEditingController phoneController;
  final String email;
  final bool saving;
  final VoidCallback onCancel;
  final VoidCallback onSave;

  @override
  Widget build(BuildContext context) {
    return _ProfileCard(
      padding: const EdgeInsets.all(13),
      child: Form(
        key: formKey,
        child: Column(
          children: [
            TextFormField(
              controller: nameController,
              decoration: const InputDecoration(
                labelText: 'Nom complet',
                isDense: true,
              ),
              validator: (value) => value == null || value.trim().length < 2
                  ? 'Saisissez votre nom'
                  : null,
            ),
            const SizedBox(height: 10),
            TextFormField(
              controller: phoneController,
              keyboardType: TextInputType.phone,
              decoration: const InputDecoration(
                labelText: 'Téléphone',
                isDense: true,
              ),
            ),
            const SizedBox(height: 10),
            InputDecorator(
              decoration: const InputDecoration(
                labelText: 'E-mail',
                isDense: true,
              ),
              child: Text(email),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: saving ? null : onCancel,
                    child: const Text('Annuler'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: FilledButton(
                    onPressed: saving ? null : onSave,
                    child: saving
                        ? const SizedBox(
                            width: 17,
                            height: 17,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Text('Enregistrer'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _PreferencesSection extends ConsumerStatefulWidget {
  const _PreferencesSection();

  @override
  ConsumerState<_PreferencesSection> createState() =>
      _PreferencesSectionState();
}

class _PreferencesSectionState extends ConsumerState<_PreferencesSection> {
  static const _green = Color(0xFF218B45);

  Future<void> _editPreferences() async {
    final current = ref.read(recoPreferencesProvider);
    final categories = ref.read(categoriesProvider);

    var selected = {...current.categoryIds};
    var maxDistance = current.maxDistanceKm;
    int? maxPrice = current.maxPrice;

    final result = await showDialog<RecoPreferences>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setState) {
          return AlertDialog(
            title: const Text('Mes préférences'),
            content: SizedBox(
              width: 520,
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Catégories favorites',
                      style: TextStyle(fontWeight: FontWeight.w700),
                    ),
                    const SizedBox(height: 10),
                    Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      children: [
                        for (final category in categories)
                          FilterChip(
                            label:
                                Text('${category['name'] ?? 'Catégorie'}'),
                            selected: selected.contains(category['id']),
                            onSelected: (value) {
                              setState(() {
                                if (value) {
                                  selected.add(category['id'] as int);
                                } else {
                                  selected.remove(category['id']);
                                }
                              });
                            },
                          ),
                      ],
                    ),
                    const SizedBox(height: 18),
                    Text(
                      'Rayon : ${maxDistance.toStringAsFixed(0)} km',
                      style: const TextStyle(fontWeight: FontWeight.w700),
                    ),
                    Slider(
                      value: maxDistance.clamp(1, 50),
                      min: 1,
                      max: 50,
                      divisions: 49,
                      activeColor: _green,
                      onChanged: (value) =>
                          setState(() => maxDistance = value),
                    ),
                    const SizedBox(height: 8),
                    DropdownButtonFormField<int?>(
                      initialValue: maxPrice,
                      decoration: const InputDecoration(
                        labelText: 'Prix maximum',
                        isDense: true,
                      ),
                      items: const [
                        DropdownMenuItem<int?>(
                          value: null,
                          child: Text('Sans limite'),
                        ),
                        DropdownMenuItem<int?>(
                          value: 500,
                          child: Text('Jusqu’à 500 FCFA'),
                        ),
                        DropdownMenuItem<int?>(
                          value: 1000,
                          child: Text('Jusqu’à 1 000 FCFA'),
                        ),
                        DropdownMenuItem<int?>(
                          value: 2000,
                          child: Text('Jusqu’à 2 000 FCFA'),
                        ),
                        DropdownMenuItem<int?>(
                          value: 5000,
                          child: Text('Jusqu’à 5 000 FCFA'),
                        ),
                      ],
                      onChanged: (value) => setState(() => maxPrice = value),
                    ),
                  ],
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext),
                child: const Text('Annuler'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(
                  dialogContext,
                  current.copyWith(
                    categoryIds: selected,
                    maxDistanceKm: maxDistance,
                    maxPrice: () => maxPrice,
                  ),
                ),
                child: const Text('Enregistrer'),
              ),
            ],
          );
        },
      ),
    );

    if (result != null) {
      await ref.read(recoPreferencesProvider.notifier).update(result);
    }
  }

  @override
  Widget build(BuildContext context) {
    final prefs = ref.watch(recoPreferencesProvider);
    final categories = ref.watch(categoriesProvider);

    final selected = <String>[
      for (final category in categories)
        if (prefs.categoryIds.contains(category['id']))
          '${category['name'] ?? 'Catégorie'}',
    ];

    return _ProfileCard(
      padding: const EdgeInsets.fromLTRB(12, 11, 12, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Expanded(
                child: Text(
                  'Mes préférences',
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w800,
                    color: _ProfileScreenState._text,
                  ),
                ),
              ),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                decoration: BoxDecoration(
                  color: const Color(0xFFE4F1DF),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: const Text(
                  'utilisées par l’IA',
                  style: TextStyle(
                    fontSize: 8.5,
                    color: _green,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              const SizedBox(width: 4),
              InkWell(
                borderRadius: BorderRadius.circular(20),
                onTap: _editPreferences,
                child: const Padding(
                  padding: EdgeInsets.all(5),
                  child: Icon(Icons.edit_outlined, size: 15),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          const _PreferenceLabel('Catégories favorites'),
          const SizedBox(height: 6),
          if (selected.isEmpty)
            const Text(
              'Aucune catégorie sélectionnée',
              style: TextStyle(fontSize: 10, color: _ProfileScreenState._muted),
            )
          else
            Wrap(
              spacing: 6,
              runSpacing: 5,
              children: [
                for (final name in selected)
                  _PreferenceChip(
                    label: name,
                    selected: true,
                  ),
              ],
            ),
          const SizedBox(height: 11),
          Row(
            children: [
              const _PreferenceLabel('Rayon de recherche'),
              const Spacer(),
              Text(
                '${prefs.maxDistanceKm.toStringAsFixed(0)} km',
                style: const TextStyle(
                  fontSize: 9.5,
                  fontWeight: FontWeight.w700,
                  color: _ProfileScreenState._text,
                ),
              ),
            ],
          ),
          SliderTheme(
            data: SliderTheme.of(context).copyWith(
              trackHeight: 4,
              thumbShape: const RoundSliderThumbShape(
                enabledThumbRadius: 5,
              ),
              overlayShape: SliderComponentShape.noOverlay,
              activeTrackColor: _green,
              inactiveTrackColor: const Color(0xFFDDE3DD),
              thumbColor: _green,
            ),
            child: Slider(
              value: prefs.maxDistanceKm.clamp(1, 50),
              min: 1,
              max: 50,
              divisions: 49,
              onChanged: (value) {
                ref
                    .read(recoPreferencesProvider.notifier)
                    .update(prefs.copyWith(maxDistanceKm: value));
              },
            ),
          ),
          const SizedBox(height: 2),
          const _PreferenceLabel('Prix maximum'),
          const SizedBox(height: 5),
          _PriceSelector(
            value: prefs.maxPrice,
            onChanged: (value) {
              ref
                  .read(recoPreferencesProvider.notifier)
                  .update(prefs.copyWith(maxPrice: () => value));
            },
          ),
          const SizedBox(height: 10),
          const _PreferenceLabel('Régime alimentaire'),
          const SizedBox(height: 6),
          const _DietSelector(),
        ],
      ),
    );
  }
}

class _PreferenceLabel extends StatelessWidget {
  const _PreferenceLabel(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: const TextStyle(
        fontSize: 9.5,
        fontWeight: FontWeight.w700,
        color: _ProfileScreenState._text,
      ),
    );
  }
}

class _PreferenceChip extends StatelessWidget {
  const _PreferenceChip({
    required this.label,
    required this.selected,
  });

  final String label;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 6),
      decoration: BoxDecoration(
        color: selected ? const Color(0xFFE7F2E8) : Colors.white,
        border: Border.all(
          color: selected
              ? _ProfileScreenState._green
              : _ProfileScreenState._border,
        ),
        borderRadius: BorderRadius.circular(15),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 9,
          fontWeight: FontWeight.w600,
          color: selected
              ? _ProfileScreenState._green
              : _ProfileScreenState._muted,
        ),
      ),
    );
  }
}

class _PriceSelector extends StatelessWidget {
  const _PriceSelector({
    required this.value,
    required this.onChanged,
  });

  final int? value;
  final ValueChanged<int?> onChanged;

  @override
  Widget build(BuildContext context) {
    return DropdownButtonFormField<int?>(
      initialValue: value,
      isExpanded: true,
      icon: const Icon(Icons.keyboard_arrow_down_rounded, size: 18),
      decoration: const InputDecoration(
        isDense: true,
        contentPadding: EdgeInsets.symmetric(horizontal: 10, vertical: 9),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.all(Radius.circular(9)),
        ),
      ),
      items: const [
        DropdownMenuItem<int?>(
          value: null,
          child: Text('Sans limite', style: TextStyle(fontSize: 10)),
        ),
        DropdownMenuItem<int?>(
          value: 500,
          child: Text('Jusqu’à 500 FCFA', style: TextStyle(fontSize: 10)),
        ),
        DropdownMenuItem<int?>(
          value: 1000,
          child: Text('Jusqu’à 1 000 FCFA', style: TextStyle(fontSize: 10)),
        ),
        DropdownMenuItem<int?>(
          value: 2000,
          child: Text('Jusqu’à 2 000 FCFA', style: TextStyle(fontSize: 10)),
        ),
        DropdownMenuItem<int?>(
          value: 5000,
          child: Text('Jusqu’à 5 000 FCFA', style: TextStyle(fontSize: 10)),
        ),
      ],
      onChanged: onChanged,
    );
  }
}

class _DietSelector extends StatefulWidget {
  const _DietSelector();

  @override
  State<_DietSelector> createState() => _DietSelectorState();
}

class _DietSelectorState extends State<_DietSelector> {
  final Set<String> _selected = {'Végétarien', 'Halal'};

  @override
  Widget build(BuildContext context) {
    const diets = [
      'Végétarien',
      'Halal',
      'Sans gluten',
      'Sans lactose',
    ];

    return Wrap(
      spacing: 6,
      runSpacing: 5,
      children: [
        for (final diet in diets)
          GestureDetector(
            onTap: () {
              setState(() {
                if (_selected.contains(diet)) {
                  _selected.remove(diet);
                } else {
                  _selected.add(diet);
                }
              });
            },
            child: _PreferenceChip(
              label: diet,
              selected: _selected.contains(diet),
            ),
          ),
      ],
    );
  }
}

class _NotificationsSection extends StatelessWidget {
  const _NotificationsSection({
    required this.pushNotifications,
    required this.favoriteAlerts,
    required this.offlineMode,
    required this.emailSummary,
    required this.onPushChanged,
    required this.onFavoritesChanged,
    required this.onOfflineChanged,
    required this.onEmailChanged,
  });

  final bool pushNotifications;
  final bool favoriteAlerts;
  final bool offlineMode;
  final bool emailSummary;
  final ValueChanged<bool> onPushChanged;
  final ValueChanged<bool> onFavoritesChanged;
  final ValueChanged<bool> onOfflineChanged;
  final ValueChanged<bool> onEmailChanged;

  @override
  Widget build(BuildContext context) {
    return _ProfileCard(
      padding: EdgeInsets.zero,
      child: Column(
        children: [
          _SettingRow(
            title: 'Notifications push',
            subtitle: 'Nouvelles offres proches de mes favoris',
            value: pushNotifications,
            onChanged: onPushChanged,
          ),
          const _ThinDivider(),
          _SettingRow(
            title: 'Alertes favoris',
            subtitle: 'Quand un commerce favori publie',
            value: favoriteAlerts,
            onChanged: onFavoritesChanged,
          ),
          const _ThinDivider(),
          _SettingRow(
            title: 'Mode hors ligne',
            subtitle: 'Télécharger les offres de ma zone (Wi-Fi)',
            value: offlineMode,
            onChanged: onOfflineChanged,
          ),
          const _ThinDivider(),
          _SettingRow(
            title: 'Résumé par e-mail',
            subtitle: 'Bilan d’impact mensuel',
            value: emailSummary,
            onChanged: onEmailChanged,
          ),
        ],
      ),
    );
  }
}

class _SettingRow extends StatelessWidget {
  const _SettingRow({
    required this.title,
    required this.subtitle,
    required this.value,
    required this.onChanged,
  });

  final String title;
  final String subtitle;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    fontSize: 10.5,
                    fontWeight: FontWeight.w700,
                    color: _ProfileScreenState._text,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  subtitle,
                  style: const TextStyle(
                    fontSize: 8.5,
                    color: _ProfileScreenState._muted,
                  ),
                ),
              ],
            ),
          ),
          Switch.adaptive(
            value: value,
            onChanged: onChanged,
            activeTrackColor: _ProfileScreenState._green,
            thumbColor: WidgetStatePropertyAll(Colors.white),
          ),
        ],
      ),
    );
  }
}

class _MenuSection extends StatelessWidget {
  const _MenuSection({required this.onPassword});

  final VoidCallback onPassword;

  @override
  Widget build(BuildContext context) {
    return _ProfileCard(
      padding: EdgeInsets.zero,
      child: Column(
        children: [
          _MenuRow(
            icon: Icons.history_outlined,
            title: 'Historique des retraits',
            onTap: () {},
          ),
          const _ThinDivider(),
          _MenuRow(
            icon: Icons.language_outlined,
            title: 'Langue · Français',
            onTap: () {},
          ),
          const _ThinDivider(),
          _MenuRow(
            icon: Icons.lock_outline,
            title: 'Modifier le mot de passe',
            onTap: onPassword,
          ),
        ],
      ),
    );
  }
}

class _MenuRow extends StatelessWidget {
  const _MenuRow({
    required this.icon,
    required this.title,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
        child: Row(
          children: [
            Icon(icon, size: 16, color: _ProfileScreenState._muted),
            const SizedBox(width: 9),
            Expanded(
              child: Text(
                title,
                style: const TextStyle(
                  fontSize: 10.5,
                  fontWeight: FontWeight.w700,
                  color: _ProfileScreenState._text,
                ),
              ),
            ),
            const Icon(
              Icons.chevron_right_rounded,
              size: 17,
              color: _ProfileScreenState._muted,
            ),
          ],
        ),
      ),
    );
  }
}

class _RoleSection extends StatelessWidget {
  const _RoleSection({
    required this.role,
    required this.actorLabel,
    required this.status,
  });

  final String role;
  final String? actorLabel;
  final String status;

  @override
  Widget build(BuildContext context) {
    return _ProfileCard(
      padding: const EdgeInsets.all(12),
      child: Row(
        children: [
          const CircleAvatar(
            radius: 19,
            backgroundColor: _ProfileScreenState._lightGreen,
            child: Icon(
              Icons.verified_user_outlined,
              color: _ProfileScreenState._green,
              size: 19,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  role,
                  style: const TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                Text(
                  actorLabel?.isNotEmpty == true
                      ? actorLabel!
                      : 'Droits adaptés à votre type de compte',
                  style: const TextStyle(
                    fontSize: 9,
                    color: _ProfileScreenState._muted,
                  ),
                ),
              ],
            ),
          ),
          Text(
            status,
            style: const TextStyle(
              fontSize: 8.5,
              color: _ProfileScreenState._green,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}

class _AssociationSection extends StatelessWidget {
  const _AssociationSection({required this.association});

  final Map<String, dynamic> association;

  @override
  Widget build(BuildContext context) {
    return _ProfileCard(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Mon association',
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w800,
              color: _ProfileScreenState._text,
            ),
          ),
          const SizedBox(height: 9),
          _CompactInfo(
            label: 'Nom',
            value: '${association['name'] ?? '—'}',
          ),
          _CompactInfo(
            label: 'N° d’enregistrement',
            value: '${association['registration_number'] ?? '—'}',
          ),
          _CompactInfo(
            label: 'Adresse',
            value: '${association['address'] ?? '—'}',
          ),
        ],
      ),
    );
  }
}

class _CompactInfo extends StatelessWidget {
  const _CompactInfo({
    required this.label,
    required this.value,
  });

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 125,
            child: Text(
              label,
              style: const TextStyle(
                fontSize: 9,
                color: _ProfileScreenState._muted,
              ),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: const TextStyle(
                fontSize: 9.5,
                fontWeight: FontWeight.w600,
                color: _ProfileScreenState._text,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ThinDivider extends StatelessWidget {
  const _ThinDivider();

  @override
  Widget build(BuildContext context) {
    return const Divider(
      height: 1,
      thickness: 0.7,
      indent: 12,
      endIndent: 12,
      color: Color(0xFFE8ECE7),
    );
  }
}

class _LogoutButton extends StatelessWidget {
  const _LogoutButton({required this.onPressed});

  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.centerLeft,
      child: TextButton(
        onPressed: onPressed,
        style: TextButton.styleFrom(
          foregroundColor: _ProfileScreenState._danger,
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 7),
        ),
        child: const Text(
          'Se déconnecter',
          style: TextStyle(
            fontSize: 10.5,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
    );
  }
}

class _ProfileCard extends StatelessWidget {
  const _ProfileCard({
    required this.child,
    this.padding = const EdgeInsets.all(12),
  });

  final Widget child;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(13),
        border: Border.all(
          color: _ProfileScreenState._border,
          width: 0.7,
        ),
      ),
      child: Padding(
        padding: padding,
        child: child,
      ),
    );
  }
}
