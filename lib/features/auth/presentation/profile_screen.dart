import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';

import 'package:repo_partage_plus/core/location/location.dart';
import 'package:repo_partage_plus/core/network/api_client.dart';
import 'package:repo_partage_plus/core/offline/offline_data.dart';
import 'package:repo_partage_plus/core/offline/sync_controller.dart';
import 'package:repo_partage_plus/core/router/app_routes.dart';
import 'package:repo_partage_plus/core/theme/app_theme.dart';
import 'package:repo_partage_plus/core/widgets/app_menu.dart';
import 'package:repo_partage_plus/core/widgets/profile_avatar.dart';
import 'package:repo_partage_plus/features/auth/data/auth_repository.dart';
import 'package:repo_partage_plus/features/auth/data/profile_repository.dart';
import 'package:repo_partage_plus/features/auth/presentation/widgets/auth_widgets.dart';
import 'package:repo_partage_plus/features/auth/presentation/widgets/logout_button.dart';
import 'package:repo_partage_plus/features/discovery/presentation/widgets/discovery_widgets.dart';
import 'package:repo_partage_plus/features/notifications/data/chat_repository.dart'
    show imageMimeType, maxChatPhotoBytes;
import 'package:repo_partage_plus/features/offers/data/offers_repository.dart';
import 'package:repo_partage_plus/features/recommendations/data/preferences.dart';

/// Profil du compte connecté (maquette) : en-tête, puis un menu vers ses
/// informations (et son association), ses préférences de recommandation et
/// sa position, son activité, et ses paramètres (notifications, sécurité).
/// Les modifications passent par la file d'attente (hors ligne compris),
/// sauf le changement de mot de passe.
class ProfileScreen extends ConsumerWidget {
  const ProfileScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final profile = ref.watch(profileProvider);
    final isAdmin = profile?['role'] == 'admin';

    return Scaffold(
      appBar: AppBar(title: const Text('Profil')),
      drawer: AppMenu(
        currentLocation: GoRouterState.of(context).uri.toString(),
      ),
      bottomNavigationBar: isAdmin ? null : const AppBottomNav(current: 4),
      body: profile == null
          ? _NoProfile(loggedIn: ref.watch(isLoggedInProvider))
          : RefreshIndicator(
              onRefresh: ref.read(syncControllerProvider.notifier).syncNow,
              child: ListView(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
                children: [
                  _Header(profile: profile),
                  const SizedBox(height: 20),
                  _ProfileMenu(profile: profile, isAdmin: isAdmin),
                  const SizedBox(height: 24),
                  FilledButton.icon(
                    onPressed: () => _openPage(
                      context,
                      _ProfilePage.information,
                      startEditing: true,
                    ),
                    icon: const Icon(Icons.edit_outlined),
                    label: const Text('Modifier le profil'),
                  ),
                  const SizedBox(height: 12),
                  OutlinedButton.icon(
                    style: OutlinedButton.styleFrom(
                      foregroundColor: AppColors.danger,
                      side: const BorderSide(color: AppColors.danger),
                    ),
                    onPressed: () => confirmLogout(context, ref),
                    icon: const Icon(Icons.logout),
                    label: const Text('Se déconnecter'),
                  ),
                ],
              ),
            ),
    );
  }
}

/// Pages ouvertes depuis le menu du profil.
enum _ProfilePage {
  information('Mes informations'),
  preferences('Mes préférences'),
  settings('Paramètres');

  const _ProfilePage(this.title);

  final String title;
}

void _openPage(
  BuildContext context,
  _ProfilePage page, {
  bool startEditing = false,
}) {
  Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => _ProfileDetail(page: page, startEditing: startEditing),
    ),
  );
}

/// Menu du profil : une ligne par rubrique (maquette).
class _ProfileMenu extends StatelessWidget {
  const _ProfileMenu({required this.profile, required this.isAdmin});

  final Json profile;
  final bool isAdmin;

  @override
  Widget build(BuildContext context) {
    final association = asJson(profile['association']);
    final entries = <(IconData, String, String?, VoidCallback)>[
      (
        Icons.person_outline,
        'Mes informations',
        association == null
            ? 'Coordonnées et compte'
            : 'Coordonnées, compte et association',
        () => _openPage(context, _ProfilePage.information),
      ),
      (
        Icons.tune,
        'Mes préférences',
        isAdmin ? 'Position' : 'Catégories, distance, prix, position',
        () => _openPage(context, _ProfilePage.preferences),
      ),
      if (!isAdmin) ...[
        (
          Icons.event_note_outlined,
          'Mes réservations',
          'Historique des réservations et retraits',
          () => context.push(AppRoutes.myReservations),
        ),
        (
          Icons.storefront_outlined,
          'Mes offres',
          'Offres publiées et leurs réservations',
          () => context.push(AppRoutes.myOffers),
        ),
        (
          Icons.eco_outlined,
          'Mon impact',
          'Produits sauvés, CO₂ évité',
          () => context.push(AppRoutes.impact),
        ),
      ],
      (
        Icons.settings_outlined,
        'Paramètres',
        'Notifications, mot de passe',
        () => _openPage(context, _ProfilePage.settings),
      ),
    ];
    return Card(
      child: Column(
        children: [
          for (final (index, (icon, title, subtitle, onTap))
              in entries.indexed) ...[
            if (index > 0) const Divider(indent: 56),
            ListTile(
              leading: Icon(icon, color: AppColors.primary),
              title: Text(
                title,
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
              subtitle: subtitle == null ? null : Text(subtitle),
              trailing: const Icon(Icons.chevron_right),
              onTap: onTap,
            ),
          ],
        ],
      ),
    );
  }
}

/// Rubrique du profil : les sections correspondantes, à jour du profil.
class _ProfileDetail extends ConsumerWidget {
  const _ProfileDetail({required this.page, this.startEditing = false});

  final _ProfilePage page;
  final bool startEditing;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final profile = ref.watch(profileProvider);
    final isAdmin = profile?['role'] == 'admin';
    final association = asJson(profile?['association']);

    return Scaffold(
      appBar: AppBar(title: Text(page.title)),
      body: profile == null
          ? _NoProfile(loggedIn: ref.watch(isLoggedInProvider))
          : ListView(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
              children: [
                ...switch (page) {
                  _ProfilePage.information => [
                    _IdentitySection(
                      profile: profile,
                      startEditing: startEditing,
                    ),
                    if (association != null)
                      _AssociationSection(association: association),
                  ],
                  _ProfilePage.preferences => [
                    if (!isAdmin) const _PreferencesSection(),
                    _PositionSection(profile: profile),
                  ],
                  _ProfilePage.settings => [
                    _NotificationsSection(isAdmin: isAdmin),
                    _SecuritySection(profile: profile),
                  ],
                }.expand((section) => [section, const SizedBox(height: 16)]),
              ],
            ),
    );
  }
}

class _NoProfile extends StatelessWidget {
  const _NoProfile({required this.loggedIn});

  final bool loggedIn;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(
              Icons.person_outline,
              size: 48,
              color: AppColors.textMuted,
            ),
            const SizedBox(height: 12),
            Text(
              loggedIn
                  ? 'Profil pas encore synchronisé : tirez vers le bas ou '
                        'revenez une fois en ligne.'
                  : 'Connectez-vous pour voir et modifier votre profil.',
              textAlign: TextAlign.center,
            ),
            if (!loggedIn) ...[
              const SizedBox(height: 16),
              FilledButton(
                onPressed: () =>
                    context.go(AppRoutes.loginThen(AppRoutes.profile)),
                child: const Text('Se connecter'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Carte de section avec un titre et, à droite, une action facultative.
class _Section extends StatelessWidget {
  const _Section({
    required this.title,
    required this.children,
    this.icon,
    this.trailing,
  });

  final String title;
  final IconData? icon;
  final Widget? trailing;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                if (icon != null) ...[
                  Icon(icon, size: 20, color: AppColors.primary),
                  const SizedBox(width: 8),
                ],
                Expanded(
                  child: Text(
                    title,
                    style: const TextStyle(
                      fontWeight: FontWeight.w700,
                      fontSize: 16,
                    ),
                  ),
                ),
                ?trailing,
              ],
            ),
            const SizedBox(height: 12),
            ...children,
          ],
        ),
      ),
    );
  }
}

void _showResult(BuildContext context, SubmitResult result, String sent) {
  switch (result) {
    case Sent():
      showMessage(context, sent);
    case Queued():
      showMessage(context, 'Hors ligne : sera envoyé au retour du réseau');
    case Rejected(:final message):
      showMessage(context, message, error: true);
  }
}

String _roleLabel(String? role) => switch (role) {
  'beneficiary' => 'Bénéficiaire',
  'donor' => 'Donateur',
  'association' => 'Association',
  'admin' => 'Administrateur',
  _ => 'Utilisateur',
};

const _months = [
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

class _Header extends StatelessWidget {
  const _Header({required this.profile});

  final Json profile;

  @override
  Widget build(BuildContext context) {
    final name = (profile['name'] as String? ?? '').trim();
    final created = DateTime.tryParse('${profile['created_at']}');
    final actor = profile['actor_label'] as String?;

    return Row(
      children: [
        _EditableAvatar(name: name, photoUrl: profilePhotoUrl(profile)),
        const SizedBox(width: 16),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                name.isEmpty ? 'Utilisateur' : name,
                style: const TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.w800,
                ),
              ),
              if (profile['email'] case final String email)
                Text(
                  email,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: AppColors.textMuted),
                ),
              if (created != null)
                Text(
                  'Membre depuis ${_months[created.month - 1]} ${created.year}',
                  style: const TextStyle(
                    color: AppColors.textMuted,
                    fontSize: 12,
                  ),
                ),
              const SizedBox(height: 6),
              Wrap(
                spacing: 6,
                runSpacing: 4,
                children: [
                  _Badge(_roleLabel(profile['role'] as String?)),
                  if (actor != null && actor.isNotEmpty) _Badge(actor),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// Ce que l'utilisateur choisit dans le menu de la photo de profil.
enum _PhotoChoice { camera, gallery, remove }

/// Photo de profil (initiales sans photo) : un appui ouvre le menu pour
/// l'ajouter, la changer ou la retirer. Envoi immédiat (réseau requis).
class _EditableAvatar extends ConsumerStatefulWidget {
  const _EditableAvatar({required this.name, required this.photoUrl});

  final String name;
  final String? photoUrl;

  @override
  ConsumerState<_EditableAvatar> createState() => _EditableAvatarState();
}

class _EditableAvatarState extends ConsumerState<_EditableAvatar> {
  var _saving = false;

  Future<void> _edit() async {
    final mobile =
        !kIsWeb &&
        (defaultTargetPlatform == TargetPlatform.android ||
            defaultTargetPlatform == TargetPlatform.iOS);
    final hasPhoto = widget.photoUrl != null;
    final choice = await showModalBottomSheet<_PhotoChoice>(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (mobile)
              ListTile(
                leading: const Icon(Icons.photo_camera_outlined),
                title: const Text('Prendre une photo'),
                onTap: () => Navigator.pop(context, _PhotoChoice.camera),
              ),
            ListTile(
              leading: const Icon(Icons.photo_library_outlined),
              title: Text(hasPhoto ? 'Changer de photo' : 'Choisir une photo'),
              onTap: () => Navigator.pop(context, _PhotoChoice.gallery),
            ),
            if (hasPhoto)
              ListTile(
                leading: const Icon(
                  Icons.delete_outline,
                  color: AppColors.danger,
                ),
                title: const Text(
                  'Retirer la photo',
                  style: TextStyle(color: AppColors.danger),
                ),
                onTap: () => Navigator.pop(context, _PhotoChoice.remove),
              ),
          ],
        ),
      ),
    );
    if (choice == null || !mounted) return;
    if (choice == _PhotoChoice.remove) return _save(null, 'Photo retirée');

    final XFile? file;
    try {
      // Photo carrée et légère : affichée en petit partout.
      file = await ImagePicker().pickImage(
        source: choice == _PhotoChoice.camera
            ? ImageSource.camera
            : ImageSource.gallery,
        maxWidth: 512,
        maxHeight: 512,
        imageQuality: 80,
        preferredCameraDevice: CameraDevice.front,
      );
    } catch (_) {
      if (mounted) {
        showMessage(context, 'Impossible d’ouvrir les photos', error: true);
      }
      return;
    }
    if (file == null) return;
    final bytes = await file.readAsBytes();
    if (!mounted) return;
    final mime = imageMimeType(bytes);
    if (mime == null) {
      showMessage(
        context,
        'Format non pris en charge : JPEG, PNG ou WebP',
        error: true,
      );
      return;
    }
    if (bytes.length > maxChatPhotoBytes) {
      showMessage(context, 'Photo trop lourde (3 Mo maximum)', error: true);
      return;
    }
    await _save(
      'data:$mime;base64,${base64Encode(bytes)}',
      'Photo de profil mise à jour',
    );
  }

  Future<void> _save(String? dataUrl, String done) async {
    setState(() => _saving = true);
    try {
      await ref.read(profileRepositoryProvider).setPhoto(dataUrl);
      if (mounted) showMessage(context, done);
    } catch (error) {
      if (mounted) showMessage(context, '$error', error: true);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    const size = 72.0;
    return Tooltip(
      message: widget.photoUrl == null
          ? 'Ajouter une photo de profil'
          : 'Modifier la photo de profil',
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: _saving ? null : _edit,
        child: SizedBox.square(
          dimension: size + 4,
          child: Stack(
            children: [
              ProfileAvatar(
                name: widget.name,
                size: size,
                photoUrl: widget.photoUrl,
              ),
              if (_saving)
                const SizedBox.square(
                  dimension: size,
                  child: Center(
                    child: CircularProgressIndicator(color: Colors.white),
                  ),
                ),
              Positioned(
                right: 0,
                bottom: 0,
                child: Container(
                  padding: const EdgeInsets.all(5),
                  decoration: BoxDecoration(
                    color: AppColors.primary,
                    shape: BoxShape.circle,
                    border: Border.all(color: Colors.white, width: 2),
                  ),
                  child: const Icon(
                    Icons.photo_camera,
                    size: 14,
                    color: Colors.white,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Badge extends StatelessWidget {
  const _Badge(this.label);

  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: const ShapeDecoration(
        color: AppColors.accentSoft,
        shape: StadiumBorder(),
      ),
      child: Text(
        label,
        style: const TextStyle(
          color: Color(0xFF9A641B),
          fontSize: 12,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

/// Coordonnées : résumé, ou formulaire après appui sur le crayon.
class _IdentitySection extends ConsumerStatefulWidget {
  const _IdentitySection({required this.profile, this.startEditing = false});

  final Json profile;

  /// Ouvre directement le formulaire (« Modifier le profil »).
  final bool startEditing;

  @override
  ConsumerState<_IdentitySection> createState() => _IdentitySectionState();
}

class _IdentitySectionState extends ConsumerState<_IdentitySection> {
  final _form = GlobalKey<FormState>();
  final _first = TextEditingController();
  final _last = TextEditingController();
  final _phone = TextEditingController();
  var _editing = false;
  var _loading = false;

  @override
  void initState() {
    super.initState();
    if (widget.startEditing) _startEditing();
  }

  @override
  void dispose() {
    for (final controller in [_first, _last, _phone]) {
      controller.dispose();
    }
    super.dispose();
  }

  void _startEditing() {
    _first.text = widget.profile['first_name'] as String? ?? '';
    _last.text = widget.profile['last_name'] as String? ?? '';
    _phone.text = widget.profile['phone'] as String? ?? '';
    setState(() => _editing = true);
  }

  String? _name(String? value) =>
      (value?.trim().length ?? 0) < 2 ? '2 caractères minimum' : null;

  Future<void> _submit() async {
    if (!_form.currentState!.validate()) return;
    setState(() => _loading = true);
    final result = await ref
        .read(profileRepositoryProvider)
        .update(
          firstName: _first.text.trim(),
          lastName: _last.text.trim(),
          phone: _phone.text.trim(),
        );
    if (!mounted) return;
    setState(() {
      _loading = false;
      if (result is! Rejected) _editing = false;
    });
    _showResult(context, result, 'Profil enregistré');
  }

  @override
  Widget build(BuildContext context) {
    final profile = widget.profile;
    final active = profile['status'] == 'active';

    return _Section(
      title: 'Mes informations',
      icon: Icons.badge_outlined,
      trailing: _editing
          ? null
          : IconButton(
              tooltip: 'Modifier',
              icon: const Icon(Icons.edit_outlined),
              onPressed: _startEditing,
            ),
      children: [
        if (!_editing) ...[
          _InfoRow(
            icon: Icons.mail_outline,
            label: 'E-mail',
            value: profile['email'] as String? ?? '—',
          ),
          _InfoRow(
            icon: Icons.phone_outlined,
            label: 'Téléphone',
            value: profile['phone'] as String? ?? '—',
          ),
          _InfoRow(
            icon: active ? Icons.verified_user_outlined : Icons.info_outline,
            label: 'Compte',
            value: active ? 'Actif' : 'En attente',
          ),
        ] else
          Form(
            key: _form,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                LabeledField(
                  label: 'Prénom',
                  child: TextFormField(
                    controller: _first,
                    textCapitalization: TextCapitalization.words,
                    validator: _name,
                  ),
                ),
                LabeledField(
                  label: 'Nom',
                  child: TextFormField(
                    controller: _last,
                    textCapitalization: TextCapitalization.words,
                    validator: _name,
                  ),
                ),
                LabeledField(
                  label: 'Téléphone',
                  child: TextFormField(
                    controller: _phone,
                    keyboardType: TextInputType.phone,
                    decoration: const InputDecoration(
                      hintText: '+226 70 00 00 00',
                    ),
                    validator: (value) =>
                        RegExp(
                          r'^\+?[0-9 ]{8,20}$',
                        ).hasMatch(value?.trim() ?? '')
                        ? null
                        : 'Numéro de téléphone invalide',
                  ),
                ),
                Text(
                  'E-mail : ${profile['email'] ?? '—'} (non modifiable)',
                  style: const TextStyle(color: AppColors.textMuted),
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton(
                        onPressed: _loading
                            ? null
                            : () => setState(() => _editing = false),
                        child: const Text('Annuler'),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: LoadingButton(
                        label: 'Enregistrer',
                        loading: _loading,
                        onPressed: _submit,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
      ],
    );
  }
}

class _InfoRow extends StatelessWidget {
  const _InfoRow({
    required this.icon,
    required this.label,
    required this.value,
  });

  final IconData icon;
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Icon(icon, size: 18, color: AppColors.textMuted),
          const SizedBox(width: 10),
          SizedBox(
            width: 90,
            child: Text(
              label,
              style: const TextStyle(color: AppColors.textMuted),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
          ),
        ],
      ),
    );
  }
}

class _AssociationSection extends StatelessWidget {
  const _AssociationSection({required this.association});

  final Json association;

  @override
  Widget build(BuildContext context) {
    return _Section(
      title: 'Mon association',
      icon: Icons.groups_outlined,
      children: [
        _InfoRow(
          icon: Icons.label_outline,
          label: 'Nom',
          value: '${association['name'] ?? '—'}',
        ),
        _InfoRow(
          icon: Icons.numbers,
          label: 'N° d’enreg.',
          value: '${association['registration_number'] ?? '—'}',
        ),
        _InfoRow(
          icon: Icons.place_outlined,
          label: 'Adresse',
          value: '${association['address'] ?? '—'}',
        ),
      ],
    );
  }
}

/// Prix maximum proposés (F CFA) ; null : sans limite.
const _priceChoices = <int?>[null, 500, 1000, 2000, 5000];

String _priceLabel(int? price) =>
    price == null ? 'Sans limite' : 'Jusqu’à $price F CFA';

/// Préférences de recommandation (catégories, rayon, prix), gardées sur
/// l'appareil et recopiées dans le compte.
class _PreferencesSection extends ConsumerWidget {
  const _PreferencesSection();

  Future<void> _editCategories(BuildContext context, WidgetRef ref) async {
    final current = ref.read(recoPreferencesProvider);
    final categories = ref.read(categoriesProvider);
    var selected = {...current.categoryIds};

    final result = await showDialog<Set<int>>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setState) => AlertDialog(
          title: const Text('Catégories favorites'),
          content: SingleChildScrollView(
            child: Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final category in categories)
                  FilterChip(
                    label: Text('${category['name']}'),
                    selected: selected.contains(category['id']),
                    onSelected: (value) => setState(() {
                      selected = {...selected};
                      final id = category['id'] as int;
                      value ? selected.add(id) : selected.remove(id);
                    }),
                  ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('Annuler'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext, selected),
              child: const Text('Enregistrer'),
            ),
          ],
        ),
      ),
    );
    if (result != null) {
      await ref
          .read(recoPreferencesProvider.notifier)
          .update(current.copyWith(categoryIds: result));
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final prefs = ref.watch(recoPreferencesProvider);
    final categories = ref.watch(categoriesProvider);
    final notifier = ref.read(recoPreferencesProvider.notifier);
    final names = [
      for (final category in categories)
        if (prefs.categoryIds.contains(category['id'])) '${category['name']}',
    ];

    return _Section(
      title: 'Mes préférences',
      icon: Icons.tune,
      trailing: const _Badge('utilisées par l’IA'),
      children: [
        Row(
          children: [
            const Expanded(
              child: Text(
                'Catégories favorites',
                style: TextStyle(fontWeight: FontWeight.w600),
              ),
            ),
            TextButton.icon(
              onPressed: () => _editCategories(context, ref),
              icon: const Icon(Icons.edit_outlined, size: 18),
              label: const Text('Choisir'),
            ),
          ],
        ),
        if (names.isEmpty)
          const Text(
            'Aucune : toutes les catégories sont proposées.',
            style: TextStyle(color: AppColors.textMuted),
          )
        else
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [for (final name in names) Chip(label: Text(name))],
          ),
        const SizedBox(height: 12),
        _RadiusSlider(
          value: prefs.maxDistanceKm,
          onChanged: (value) =>
              notifier.update(prefs.copyWith(maxDistanceKm: value)),
        ),
        const SizedBox(height: 8),
        DropdownButtonFormField<int?>(
          key: ValueKey(prefs.maxPrice),
          initialValue: _priceChoices.contains(prefs.maxPrice)
              ? prefs.maxPrice
              : null,
          isExpanded: true,
          decoration: const InputDecoration(labelText: 'Prix maximum'),
          items: [
            for (final price in _priceChoices)
              DropdownMenuItem(value: price, child: Text(_priceLabel(price))),
          ],
          onChanged: (value) =>
              notifier.update(prefs.copyWith(maxPrice: () => value)),
        ),
        const SizedBox(height: 8),
        TextButton.icon(
          onPressed: () => context.push(AppRoutes.recommendations),
          icon: const Icon(Icons.auto_awesome_outlined),
          label: const Text('Voir mes recommandations'),
        ),
      ],
    );
  }
}

/// Rayon : affiché pendant le glissement, enregistré au relâchement.
class _RadiusSlider extends StatefulWidget {
  const _RadiusSlider({required this.value, required this.onChanged});

  final double value;
  final ValueChanged<double> onChanged;

  @override
  State<_RadiusSlider> createState() => _RadiusSliderState();
}

class _RadiusSliderState extends State<_RadiusSlider> {
  double? _dragging;

  @override
  Widget build(BuildContext context) {
    final value = (_dragging ?? widget.value).clamp(1.0, 50.0);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            const Expanded(
              child: Text(
                'Rayon de recherche',
                style: TextStyle(fontWeight: FontWeight.w600),
              ),
            ),
            Text(
              '${value.round()} km',
              style: const TextStyle(fontWeight: FontWeight.w700),
            ),
          ],
        ),
        Slider(
          value: value,
          min: 1,
          max: 50,
          divisions: 49,
          label: '${value.round()} km',
          onChanged: (next) => setState(() => _dragging = next),
          onChangeEnd: (next) {
            setState(() => _dragging = null);
            widget.onChanged(next);
          },
        ),
      ],
    );
  }
}

class _PositionSection extends ConsumerStatefulWidget {
  const _PositionSection({required this.profile});

  final Json profile;

  @override
  ConsumerState<_PositionSection> createState() => _PositionSectionState();
}

class _PositionSectionState extends ConsumerState<_PositionSection> {
  var _loading = false;

  Future<void> _useCurrent() async {
    setState(() => _loading = true);
    try {
      final place = await ref.read(locationGatewayProvider).currentPosition();
      final result = await ref
          .read(profileRepositoryProvider)
          .update(latitude: place.lat, longitude: place.lng);
      if (mounted) _showResult(context, result, 'Position enregistrée');
    } on LocationFailure catch (failure) {
      if (mounted) showMessage(context, failure.message, error: true);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final lat = (widget.profile['latitude'] as num?)?.toDouble();
    final lng = (widget.profile['longitude'] as num?)?.toDouble();
    return _Section(
      title: 'Ma position',
      icon: Icons.place_outlined,
      children: [
        Text(
          lat == null || lng == null
              ? 'Aucune position enregistrée : les recommandations du serveur '
                    'ne tiennent pas compte de la distance.'
              : 'Position enregistrée : ${lat.toStringAsFixed(4)}, '
                    '${lng.toStringAsFixed(4)}',
          style: const TextStyle(color: AppColors.textMuted),
        ),
        const SizedBox(height: 12),
        OutlinedButton.icon(
          onPressed: _loading ? null : _useCurrent,
          icon: _loading
              ? const SizedBox.square(
                  dimension: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.my_location),
          label: const Text('Utiliser ma position actuelle'),
        ),
      ],
    );
  }
}

class _NotificationsSection extends ConsumerWidget {
  const _NotificationsSection({required this.isAdmin});

  final bool isAdmin;

  Future<void> _save(
    BuildContext context,
    WidgetRef ref,
    String key,
    bool value,
    String label,
  ) async {
    final result = await ref.read(profileRepositoryProvider).savePreferences({
      key: value,
    });
    if (context.mounted) {
      _showResult(
        context,
        result,
        '$label ${value ? 'activées' : 'désactivées'}',
      );
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return _Section(
      title: 'Notifications',
      icon: Icons.notifications_none,
      children: [
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Notifications sur le téléphone'),
          subtitle: const Text(
            'Réservations, confirmations, retraits. Elles restent visibles '
            'dans l’écran Notifications.',
          ),
          value: ref.watch(pushEnabledProvider),
          onChanged: (value) =>
              _save(context, ref, 'push_enabled', value, 'Notifications'),
        ),
        if (!isAdmin)
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Alertes de mes recherches'),
            subtitle: const Text(
              'Prévenu quand une nouvelle offre correspond à une recherche '
              'enregistrée.',
            ),
            value: ref.watch(searchAlertsEnabledProvider),
            onChanged: (value) =>
                _save(context, ref, 'search_alerts', value, 'Alertes'),
          ),
      ],
    );
  }
}

class _SecuritySection extends ConsumerStatefulWidget {
  const _SecuritySection({required this.profile});

  final Json profile;

  @override
  ConsumerState<_SecuritySection> createState() => _SecuritySectionState();
}

class _SecuritySectionState extends ConsumerState<_SecuritySection> {
  final _form = GlobalKey<FormState>();
  final _current = TextEditingController();
  final _next = TextEditingController();
  final _confirm = TextEditingController();
  var _open = false;
  var _loading = false;

  @override
  void dispose() {
    for (final controller in [_current, _next, _confirm]) {
      controller.dispose();
    }
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_form.currentState!.validate()) return;
    setState(() => _loading = true);
    try {
      await ref
          .read(profileRepositoryProvider)
          .changePassword(current: _current.text, next: _next.text);
      if (!mounted) return;
      for (final controller in [_current, _next, _confirm]) {
        controller.clear();
      }
      setState(() => _open = false);
      showMessage(context, 'Mot de passe modifié');
    } on ApiException catch (error) {
      if (mounted) showMessage(context, error.message, error: true);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final email = widget.profile['email'] as String? ?? '';
    // Compte Firebase : le mot de passe se change par code reçu par e-mail.
    final firebase = widget.profile['firebase_uid'] != null;

    return _Section(
      title: 'Sécurité',
      icon: Icons.lock_outline,
      children: [
        if (firebase || !_open)
          OutlinedButton.icon(
            onPressed: () => firebase
                ? context.push(AppRoutes.forgotPasswordFor(email))
                : setState(() => _open = true),
            icon: const Icon(Icons.password),
            label: const Text('Changer mon mot de passe'),
          )
        else
          Form(
            key: _form,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                LabeledField(
                  label: 'Mot de passe actuel',
                  child: PasswordField(
                    controller: _current,
                    hint: '',
                    validator: requiredField('Mot de passe actuel requis'),
                  ),
                ),
                LabeledField(
                  label: 'Nouveau mot de passe',
                  child: PasswordField(
                    controller: _next,
                    hint: '',
                    validator: validatePassword,
                  ),
                ),
                LabeledField(
                  label: 'Confirmer',
                  child: PasswordField(
                    controller: _confirm,
                    hint: '',
                    validator: (value) => value != _next.text
                        ? 'Les mots de passe ne correspondent pas'
                        : null,
                  ),
                ),
                LoadingButton(
                  label: 'Modifier le mot de passe',
                  loading: _loading,
                  onPressed: _submit,
                ),
                TextButton(
                  onPressed: () => setState(() => _open = false),
                  child: const Text('Annuler'),
                ),
              ],
            ),
          ),
      ],
    );
  }
}
