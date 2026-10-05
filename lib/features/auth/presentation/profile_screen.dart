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

/// Profil du compte connecté : identité, coordonnées, position (pour les
/// recommandations), sécurité, notifications et préférences. Les
/// modifications passent par la file d'attente (hors ligne compris).
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
                padding: const EdgeInsets.all(16),
                children: [
                  _Header(profile: profile),
                  const SizedBox(height: 16),
                  _IdentitySection(profile: profile),
                  const SizedBox(height: 16),
                  _PositionSection(profile: profile),
                  const SizedBox(height: 16),
                  _SecuritySection(profile: profile),
                  const SizedBox(height: 16),
                  const _NotificationsSection(),
                  if (!isAdmin) ...[
                    const SizedBox(height: 16),
                    const _ShortcutsSection(),
                  ],
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

/// Carte de section avec un titre.
class _Section extends StatelessWidget {
  const _Section({required this.title, required this.children, this.icon});

  final String title;
  final IconData? icon;
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
                Text(
                  title,
                  style: const TextStyle(
                    fontWeight: FontWeight.w700,
                    fontSize: 16,
                  ),
                ),
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

class _Header extends StatelessWidget {
  const _Header({required this.profile});

  final Json profile;

  @override
  Widget build(BuildContext context) {
    final name = profile['name'] as String? ?? '';
    final association = asJson(profile['association']);
    final status = association?['status'] as String?;
    final (statusLabel, statusColor) = switch (status) {
      'approved' => ('Association validée', AppColors.primary),
      'rejected' => ('Association refusée', AppColors.danger),
      'pending' => ('Association en attente de validation', AppColors.accent),
      _ => (null, AppColors.textMuted),
    };

    return Row(
      children: [
        CircleAvatar(
          radius: 32,
          backgroundColor: AppColors.primarySoft,
          foregroundColor: AppColors.primary,
          child: Text(
            name.isEmpty ? '?' : name[0].toUpperCase(),
            style: const TextStyle(fontSize: 26, fontWeight: FontWeight.w800),
          ),
        ),
        const SizedBox(width: 16),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                name,
                style: const TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.w800,
                ),
              ),
              Text(
                profile['email'] as String? ?? '',
                style: const TextStyle(color: AppColors.textMuted),
              ),
              if (profile['actor_label'] case final String actor)
                Text(
                  actor,
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
              if (statusLabel != null)
                Text(
                  association?['name'] == null
                      ? statusLabel
                      : '${association!['name']} · $statusLabel',
                  style: TextStyle(color: statusColor, fontSize: 12),
                ),
              if (status == 'rejected' &&
                  association?['review_reason'] is String)
                Text(
                  'Motif : ${association!['review_reason']}',
                  style: const TextStyle(fontSize: 12),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

class _IdentitySection extends ConsumerStatefulWidget {
  const _IdentitySection({required this.profile});

  final Json profile;

  @override
  ConsumerState<_IdentitySection> createState() => _IdentitySectionState();
}

class _IdentitySectionState extends ConsumerState<_IdentitySection> {
  final _form = GlobalKey<FormState>();
  late final _first = TextEditingController(
    text: widget.profile['first_name'] as String?,
  );
  late final _last = TextEditingController(
    text: widget.profile['last_name'] as String?,
  );
  late final _phone = TextEditingController(
    text: widget.profile['phone'] as String?,
  );
  var _loading = false;

  @override
  void dispose() {
    for (final controller in [_first, _last, _phone]) {
      controller.dispose();
    }
    super.dispose();
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
    setState(() => _loading = false);
    _showResult(context, result, 'Profil enregistré');
  }

  @override
  Widget build(BuildContext context) {
    return _Section(
      title: 'Mes informations',
      icon: Icons.badge_outlined,
      children: [
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
                      RegExp(r'^\+?[0-9 ]{8,20}$').hasMatch(value?.trim() ?? '')
                      ? null
                      : 'Numéro de téléphone invalide',
                ),
              ),
              LoadingButton(
                label: 'Enregistrer',
                loading: _loading,
                onPressed: _submit,
              ),
            ],
          ),
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
                    validator: (value) {
                      final text = value ?? '';
                      if (text.length < 8) return '8 caractères minimum';
                      if (!RegExp('[0-9]').hasMatch(text) ||
                          !RegExp('[A-Za-z]').hasMatch(text)) {
                        return 'Au moins une lettre et un chiffre';
                      }
                      return null;
                    },
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

class _NotificationsSection extends ConsumerWidget {
  const _NotificationsSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final enabled = ref.watch(pushEnabledProvider);
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
          value: enabled,
          onChanged: (value) async {
            final result = await ref
                .read(profileRepositoryProvider)
                .savePreferences({'push_enabled': value});
            if (context.mounted) {
              _showResult(
                context,
                result,
                value ? 'Notifications activées' : 'Notifications désactivées',
              );
            }
          },
        ),
      ],
    );
  }
}

class _ShortcutsSection extends StatelessWidget {
  const _ShortcutsSection();

  @override
  Widget build(BuildContext context) {
    const links = [
      (Icons.tune, 'Préférences de recommandation', AppRoutes.recommendations),
      (Icons.storefront_outlined, 'Mes offres', AppRoutes.myOffers),
      (
        Icons.event_available_outlined,
        'Mes réservations',
        AppRoutes.myReservations,
      ),
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
