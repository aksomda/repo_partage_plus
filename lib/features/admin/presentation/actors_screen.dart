import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'package:repo_partage_plus/core/offline/offline_data.dart';
import 'package:repo_partage_plus/core/offline/sync_controller.dart';
import 'package:repo_partage_plus/core/theme/app_theme.dart';
import 'package:repo_partage_plus/core/widgets/actor_icon.dart';
import 'package:repo_partage_plus/core/widgets/app_menu.dart';
import 'package:repo_partage_plus/features/admin/data/admin_repository.dart';
import 'package:repo_partage_plus/features/auth/presentation/widgets/auth_widgets.dart';

/// Configuration des acteurs (particulier, restaurateur, commerçant,
/// administrateur…) : libellé, droits, visibilité à l'inscription.
class ActorsScreen extends ConsumerWidget {
  const ActorsScreen({super.key});

  Future<void> _edit(BuildContext context, WidgetRef ref, [Json? actor]) async {
    final saved = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      backgroundColor: AppColors.surface,
      builder: (context) => _ActorForm(actor: actor),
    );
    if (saved == true && context.mounted) {
      showMessage(context, 'Acteur enregistré');
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final actors = ref.watch(actorsProvider);
    final waiting = {
      for (final action in ref.watch(waitingActionsProvider))
        if (action.kind.startsWith('actor.') && action.targetId != null)
          action.targetId,
    };
    final syncing = ref.watch(syncControllerProvider).syncing;

    return Scaffold(
      appBar: AppBar(title: const Text('Acteurs')),
      drawer: AppMenu(
        currentLocation: GoRouterState.of(context).uri.toString(),
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _edit(context, ref),
        backgroundColor: AppColors.primary,
        shape: const StadiumBorder(),
        icon: const Icon(Icons.add),
        label: const Text('Ajouter un acteur'),
      ),
      body: RefreshIndicator(
        onRefresh: ref.read(syncControllerProvider.notifier).syncNow,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 96),
          children: [
            const Text(
              'Les acteurs sont les profils proposés à l’inscription. '
              'Leurs droits déterminent ce que le compte peut faire.',
              style: TextStyle(color: AppColors.textMuted),
            ),
            const SizedBox(height: 16),
            if (actors.isEmpty)
              Padding(
                padding: const EdgeInsets.all(32),
                child: Center(
                  child: syncing
                      ? const CircularProgressIndicator()
                      : const Text(
                          'Aucun acteur synchronisé : tirez vers le bas '
                          'pour actualiser.',
                          textAlign: TextAlign.center,
                        ),
                ),
              ),
            for (final actor in actors)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: _ActorTile(
                  actor: actor,
                  waiting: waiting.contains(actor['id']),
                  onTap: () => _edit(context, ref, actor),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _ActorTile extends StatelessWidget {
  const _ActorTile({
    required this.actor,
    required this.waiting,
    required this.onTap,
  });

  final Json actor;
  final bool waiting;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final active = _flag(actor['active']);
    final selfSignup = _flag(actor['self_signup']);
    final count = actor['users_count'] as int? ?? 0;

    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Opacity(
          opacity: active ? 1 : 0.55,
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                ActorAvatar(actor: actor),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        actor['label'] as String,
                        style: const TextStyle(
                          fontWeight: FontWeight.w700,
                          fontSize: 16,
                        ),
                      ),
                      Text(
                        permissionLabels[actor['permission_role']] ?? '',
                        style: const TextStyle(color: AppColors.textMuted),
                      ),
                      const SizedBox(height: 6),
                      Wrap(
                        spacing: 6,
                        runSpacing: 4,
                        children: [
                          _Tag(
                            selfSignup
                                ? 'Proposé à l’inscription'
                                : 'Masqué à l’inscription',
                            highlighted: selfSignup,
                          ),
                          if (!active) const _Tag('Inactif'),
                          _Tag('$count compte${count > 1 ? 's' : ''}'),
                          if (waiting)
                            const _Tag('En attente d’envoi', warning: true),
                        ],
                      ),
                    ],
                  ),
                ),
                const Icon(Icons.edit_outlined, color: AppColors.textMuted),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _Tag extends StatelessWidget {
  const _Tag(this.label, {this.highlighted = false, this.warning = false});

  final String label;
  final bool highlighted;
  final bool warning;

  @override
  Widget build(BuildContext context) {
    final color = warning
        ? AppColors.accent
        : highlighted
        ? AppColors.primary
        : AppColors.textMuted;
    final background = warning
        ? AppColors.accentSoft
        : highlighted
        ? AppColors.primarySoft
        : AppColors.background;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: ShapeDecoration(
        color: background,
        shape: const StadiumBorder(),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: color,
          fontSize: 11,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

/// MySQL renvoie les booléens sous forme 0/1.
bool _flag(Object? value) => value == true || value == 1;

class _ActorForm extends ConsumerStatefulWidget {
  const _ActorForm({this.actor});

  /// null : création.
  final Json? actor;

  @override
  ConsumerState<_ActorForm> createState() => _ActorFormState();
}

class _ActorFormState extends ConsumerState<_ActorForm> {
  final _form = GlobalKey<FormState>();
  late final _label = TextEditingController(text: widget.actor?['label']);
  late final _code = TextEditingController(text: widget.actor?['code']);
  late final _description = TextEditingController(
    text: widget.actor?['description'],
  );
  late final _order = TextEditingController(
    text: '${widget.actor?['sort_order'] ?? 0}',
  );
  late String _icon = widget.actor?['icon'] as String? ?? 'person';
  late String _role =
      widget.actor?['permission_role'] as String? ?? 'beneficiary';
  late bool _selfSignup = widget.actor == null
      ? true
      : _flag(widget.actor!['self_signup']);
  late bool _active = widget.actor == null || _flag(widget.actor!['active']);
  var _codeEdited = false;
  var _loading = false;

  bool get _creating => widget.actor == null;
  int get _usersCount => widget.actor?['users_count'] as int? ?? 0;

  @override
  void dispose() {
    for (final controller in [_label, _code, _description, _order]) {
      controller.dispose();
    }
    super.dispose();
  }

  /// « Commerçant » → « commercant ».
  static String _slug(String value) {
    const accents = {
      'à': 'a', 'â': 'a', 'ä': 'a', 'ç': 'c', 'é': 'e', 'è': 'e', //
      'ê': 'e', 'ë': 'e', 'î': 'i', 'ï': 'i', 'ô': 'o', 'ö': 'o',
      'ù': 'u', 'û': 'u', 'ü': 'u', 'ÿ': 'y',
    };
    final lower = value.toLowerCase().split('').map((c) => accents[c] ?? c);
    return lower
        .join()
        .replaceAll(RegExp(r'[^a-z0-9]+'), '-')
        .replaceAll(RegExp(r'^-+|-+$'), '');
  }

  Future<void> _submit() async {
    if (!_form.currentState!.validate()) return;
    setState(() => _loading = true);

    final result = await ref
        .read(adminRepositoryProvider)
        .saveActor(
          id: widget.actor?['id'] as int?,
          code: _code.text.trim(),
          label: _label.text.trim(),
          description: _description.text.trim().isEmpty
              ? null
              : _description.text.trim(),
          icon: _icon,
          permissionRole: _role,
          selfSignup: _role != 'admin' && _selfSignup,
          active: _active,
          sortOrder: int.tryParse(_order.text) ?? 0,
        );
    if (!mounted) return;
    setState(() => _loading = false);
    _handle(result, closeWith: true);
  }

  Future<void> _delete() async {
    final label = widget.actor!['label'] as String;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Supprimer « $label » ?'),
        content: const Text('Il ne sera plus proposé à l’inscription.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Annuler'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppColors.danger),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Supprimer'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    final result = await ref
        .read(adminRepositoryProvider)
        .deleteActor(widget.actor!['id'] as int, label);
    if (mounted) _handle(result, closeWith: false);
  }

  void _handle(SubmitResult result, {required bool closeWith}) {
    switch (result) {
      case Sent():
        Navigator.of(context).pop(closeWith);
      case Queued():
        showMessage(context, 'Hors ligne : sera envoyé au retour du réseau');
        Navigator.of(context).pop(false);
      case Rejected(:final message):
        showMessage(context, message, error: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final bottom = MediaQuery.viewInsetsOf(context).bottom;
    final roleLocked = !_creating && _usersCount > 0;

    return Padding(
      padding: EdgeInsets.fromLTRB(24, 0, 24, 24 + bottom),
      child: SingleChildScrollView(
        child: Form(
          key: _form,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                _creating ? 'Nouvel acteur' : 'Modifier l’acteur',
                style: Theme.of(
                  context,
                ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 20),
              LabeledField(
                label: 'Libellé',
                child: TextFormField(
                  controller: _label,
                  textCapitalization: TextCapitalization.sentences,
                  decoration: const InputDecoration(hintText: 'Ex. : Traiteur'),
                  validator: requiredField('Libellé obligatoire'),
                  onChanged: (value) {
                    if (_creating && !_codeEdited) _code.text = _slug(value);
                  },
                ),
              ),
              LabeledField(
                label: 'Code (identifiant unique)',
                child: TextFormField(
                  controller: _code,
                  decoration: const InputDecoration(hintText: 'traiteur'),
                  onChanged: (_) => _codeEdited = true,
                  validator: (value) =>
                      RegExp(
                        r'^[a-z0-9_-]{2,40}$',
                      ).hasMatch(value?.trim() ?? '')
                      ? null
                      : 'Minuscules, chiffres, - ou _ (2 à 40)',
                ),
              ),
              LabeledField(
                label: 'Description affichée à l’inscription',
                child: TextFormField(
                  controller: _description,
                  maxLength: 255,
                  decoration: const InputDecoration(
                    hintText: 'Je souhaite publier des produits',
                  ),
                ),
              ),
              LabeledField(
                label: 'Icône',
                child: Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final entry in actorIcons.entries)
                      ChoiceChip(
                        label: Icon(
                          entry.value,
                          size: 20,
                          color: _icon == entry.key
                              ? Colors.white
                              : AppColors.text,
                        ),
                        selected: _icon == entry.key,
                        onSelected: (_) => setState(() => _icon = entry.key),
                        tooltip: entry.key,
                      ),
                  ],
                ),
              ),
              LabeledField(
                label: 'Droits',
                child: DropdownButtonFormField<String>(
                  initialValue: _role,
                  items: [
                    for (final entry in permissionLabels.entries)
                      DropdownMenuItem(
                        value: entry.key,
                        child: Text(entry.value),
                      ),
                  ],
                  onChanged: roleLocked
                      ? null
                      : (value) => setState(() {
                          _role = value!;
                          if (_role == 'admin') _selfSignup = false;
                        }),
                  decoration: InputDecoration(
                    helperText: roleLocked
                        ? 'Non modifiable : $_usersCount compte(s) l’utilisent'
                        : null,
                  ),
                ),
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Proposé à l’inscription'),
                subtitle: Text(
                  _role == 'admin'
                      ? 'Impossible pour un administrateur'
                      : 'Visible sur l’écran « Choisissez votre rôle »',
                ),
                value: _role != 'admin' && _selfSignup,
                onChanged: _role == 'admin'
                    ? null
                    : (value) => setState(() => _selfSignup = value),
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Actif'),
                subtitle: const Text(
                  'Un acteur inactif n’est plus proposé ; '
                  'les comptes existants sont conservés',
                ),
                value: _active,
                onChanged: (value) => setState(() => _active = value),
              ),
              const SizedBox(height: 8),
              LabeledField(
                label: 'Ordre d’affichage',
                child: TextFormField(
                  controller: _order,
                  keyboardType: TextInputType.number,
                ),
              ),
              LoadingButton(
                label: 'Enregistrer',
                loading: _loading,
                onPressed: _submit,
              ),
              if (!_creating) ...[
                const SizedBox(height: 8),
                TextButton.icon(
                  style: TextButton.styleFrom(
                    foregroundColor: AppColors.danger,
                  ),
                  onPressed: _usersCount > 0 ? null : _delete,
                  icon: const Icon(Icons.delete_outline),
                  label: Text(
                    _usersCount > 0
                        ? 'Suppression impossible : le désactiver'
                        : 'Supprimer',
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
