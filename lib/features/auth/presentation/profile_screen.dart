import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'package:repo_partage_plus/core/location/location.dart';
import 'package:repo_partage_plus/core/network/api_client.dart';
import 'package:repo_partage_plus/core/offline/offline_data.dart';
import 'package:repo_partage_plus/core/offline/sync_controller.dart';
import 'package:repo_partage_plus/core/router/app_routes.dart';
import 'package:repo_partage_plus/core/theme/app_theme.dart';
import 'package:repo_partage_plus/core/widgets/app_menu.dart';
import 'package:repo_partage_plus/features/auth/data/auth_repository.dart';
import 'package:repo_partage_plus/features/auth/data/profile_repository.dart';
import 'package:repo_partage_plus/features/auth/presentation/widgets/auth_widgets.dart';
import 'package:repo_partage_plus/features/auth/presentation/widgets/logout_button.dart';
import 'package:repo_partage_plus/features/discovery/presentation/widgets/discovery_widgets.dart';
import 'package:repo_partage_plus/features/offers/data/offers_repository.dart';
import 'package:repo_partage_plus/features/recommendations/data/preferences.dart';

/// Profil du compte connecté : identité, association, préférences de
/// recommandation, position, notifications, activité et sécurité. Les
/// modifications passent par la file d'attente (hors ligne compris), sauf
/// le changement de mot de passe.
class ProfileScreen extends ConsumerWidget {
  const ProfileScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final profile = ref.watch(profileProvider);
    final isAdmin = profile?['role'] == 'admin';
    final association = asJson(profile?['association']);

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
                  const SizedBox(height: 16),
                  _IdentitySection(profile: profile),
                  if (association != null) ...[
                    const SizedBox(height: 16),
                    _AssociationSection(association: association),
                  ],
                  if (!isAdmin) ...[
                    const SizedBox(height: 16),
                    const _PreferencesSection(),
                  ],
                  const SizedBox(height: 16),
                  _PositionSection(profile: profile),
                  const SizedBox(height: 16),
                  _NotificationsSection(isAdmin: isAdmin),
                  if (!isAdmin) ...[
                    const SizedBox(height: 16),
                    const _ActivitySection(),
                  ],
                  const SizedBox(height: 16),
                  _SecuritySection(profile: profile),
                  const SizedBox(height: 24),
                  OutlinedButton.icon(
                    style: OutlinedButton.styleFrom(
                      foregroundColor: AppColors.danger,
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

/// Initiales du prénom et du nom (« Awa Traoré » → « AT »).
String profileInitials(String name) {
  final parts = name.split(RegExp(r'\s+')).where((p) => p.isNotEmpty).toList();
  if (parts.isEmpty) return '?';
  if (parts.length == 1) return parts.first[0].toUpperCase();
  return '${parts.first[0]}${parts.last[0]}'.toUpperCase();
}

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
        Container(
          width: 64,
          height: 64,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: AppColors.accent,
            borderRadius: BorderRadius.circular(16),
          ),
          child: Text(
            profileInitials(name),
            style: const TextStyle(
              color: Colors.white,
              fontSize: 22,
              fontWeight: FontWeight.w800,
            ),
          ),
        ),
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
              if (created != null)
                Text(
                  'Membre depuis ${_months[created.month - 1]} ${created.year}',
                  style: const TextStyle(color: AppColors.textMuted),
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
  const _IdentitySection({required this.profile});

  final Json profile;

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
    final status = association['status'] as String?;
    final (statusLabel, statusColor) = switch (status) {
      'approved' => ('Validée', AppColors.primary),
      'rejected' => ('Refusée', AppColors.danger),
      _ => ('En attente de validation', AppColors.accent),
    };
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
        const SizedBox(height: 4),
        Text(
          'Statut : $statusLabel',
          style: TextStyle(color: statusColor, fontWeight: FontWeight.w700),
        ),
        if (status == 'pending')
          const Text(
            'Vous pourrez réserver dès la validation par un administrateur.',
            style: TextStyle(color: AppColors.textMuted),
          ),
        if (status == 'rejected' && association['review_reason'] is String)
          Text('Motif : ${association['review_reason']}'),
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

class _ActivitySection extends StatelessWidget {
  const _ActivitySection();

  @override
  Widget build(BuildContext context) {
    const links = [
      (
        Icons.history_outlined,
        'Historique des réservations et retraits',
        AppRoutes.myReservations,
      ),
      (Icons.storefront_outlined, 'Mes offres', AppRoutes.myOffers),
      (Icons.eco_outlined, 'Mon impact', AppRoutes.impact),
    ];
    return _Section(
      title: 'Mon activité',
      icon: Icons.dashboard_customize_outlined,
      children: [
        for (final (icon, label, route) in links)
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: Icon(icon),
            title: Text(label),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => context.push(route),
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
                  child: TextFormField(
                    controller: _current,
                    obscureText: true,
                    validator: requiredField('Mot de passe actuel requis'),
                  ),
                ),
                LabeledField(
                  label: 'Nouveau mot de passe',
                  child: TextFormField(
                    controller: _next,
                    obscureText: true,
                    validator: validatePassword,
                  ),
                ),
                LabeledField(
                  label: 'Confirmer',
                  child: TextFormField(
                    controller: _confirm,
                    obscureText: true,
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
