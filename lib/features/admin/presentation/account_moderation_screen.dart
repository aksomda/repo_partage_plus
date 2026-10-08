import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'package:repo_partage_plus/core/offline/offline_data.dart';
import 'package:repo_partage_plus/core/offline/sync_controller.dart';
import 'package:repo_partage_plus/core/router/app_routes.dart';
import 'package:repo_partage_plus/core/theme/app_theme.dart';
import 'package:repo_partage_plus/features/admin/data/admin_repository.dart';
import 'package:repo_partage_plus/features/admin/presentation/widgets/admin_shell.dart';
import 'package:repo_partage_plus/features/auth/presentation/widgets/auth_widgets.dart';

/// Gestion des utilisateurs : l'administrateur ajoute, désactive ou réactive
/// un compte. La liste vient de la copie locale (jamais de plantage hors
/// ligne) ; chaque modification passe par la file d'attente et est envoyée
/// au retour du réseau.
class AccountModerationScreen extends ConsumerStatefulWidget {
  const AccountModerationScreen({super.key});

  @override
  ConsumerState<AccountModerationScreen> createState() =>
      _AccountModerationScreenState();
}

class _AccountModerationScreenState
    extends ConsumerState<AccountModerationScreen> {
  static const _tabs = [
    (label: 'Tous', status: null),
    (label: 'Actifs', status: 'active'),
    (label: 'Désactivés', status: 'suspended'),
    (label: 'Non activés', status: 'pending'),
  ];

  final _search = TextEditingController();
  var _tab = 0;
  var _query = '';
  var _refreshing = false;

  @override
  void initState() {
    super.initState();
    // Copie locale affichée tout de suite, actualisée en arrière-plan.
    WidgetsBinding.instance.addPostFrameCallback((_) => _refresh());
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Future<void> _refresh({bool manual = false}) async {
    if (_refreshing) return;
    // Sans réseau, on n'essaie même pas : la copie locale reste affichée, et
    // la synchronisation se fera d'elle-même au retour de la connexion.
    if (!(ref.read(onlineProvider).value ?? false)) {
      if (manual) {
        showMessage(
          context,
          'Hors ligne : dernière copie enregistrée sur l’appareil',
          error: true,
        );
      }
      return;
    }
    setState(() => _refreshing = true);
    final result = await ref.read(adminRepositoryProvider).refreshUsers();
    if (!mounted) return;
    setState(() => _refreshing = false);
    if (!manual) return;
    switch (result) {
      case UsersRefresh.mysql:
        showMessage(context, 'Liste des comptes à jour');
      case UsersRefresh.firestore:
        showMessage(context, 'Base principale indisponible : copie Firebase');
      case UsersRefresh.offline:
        showMessage(
          context,
          'Hors ligne : dernière copie enregistrée sur l’appareil',
          error: true,
        );
    }
  }

  Future<void> _toggle(Json user, bool activate) async {
    final name = user['name'] as String? ?? '';
    final String? reason;
    if (activate) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Réactiver le compte ?'),
          content: Text('$name pourra de nouveau se connecter.'),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Annuler'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('Réactiver'),
            ),
          ],
        ),
      );
      if (confirmed != true) return;
      reason = null;
    } else {
      reason = await showDialog<String>(
        context: context,
        builder: (context) => _DeactivateDialog(name: name),
      );
      if (reason == null) return;
    }

    final result = await ref
        .read(adminRepositoryProvider)
        .setUserStatus(user['id'] as int, suspended: !activate, reason: reason);
    if (!mounted) return;
    _report(
      result,
      activate ? 'Compte de $name réactivé' : 'Compte de $name désactivé',
    );
  }

  Future<void> _add() async {
    final result = await showDialog<SubmitResult>(
      context: context,
      builder: (context) => const _AddUserDialog(),
    );
    if (result == null || !mounted) return;
    _report(result, 'Compte créé : il peut se connecter dès maintenant');
  }

  void _report(SubmitResult result, String sent) {
    switch (result) {
      case Sent():
        showMessage(context, sent);
      case Queued():
        showMessage(
          context,
          'Enregistré sur l’appareil : envoyé au retour de la connexion',
        );
      case Rejected(:final message):
        showMessage(context, message, error: true);
    }
  }

  Future<void> _details(Json user) {
    return showDialog<void>(
      context: context,
      builder: (context) => _UserDetailsDialog(user: user),
    );
  }

  @override
  Widget build(BuildContext context) {
    final all = ref.watch(adminUsersProvider);
    final source = ref.watch(adminUsersSourceProvider);
    final hasSnapshot = ref.watch(snapshotProvider('admin')).value != null;
    final found = searchUsers(all, _query);
    int count(String? status) => status == null
        ? found.length
        : found.where((user) => effectiveStatus(user) == status).length;
    final status = _tabs[_tab].status;
    final users = status == null
        ? found
        : found.where((user) => effectiveStatus(user) == status).toList();

    return AdminShell(
      title: 'Gestion des utilisateurs',
      current: AppRoutes.adminAccounts,
      actions: [
        IconButton(
          tooltip: 'Actualiser',
          onPressed: _refreshing ? null : () => _refresh(manual: true),
          icon: _refreshing
              ? const SizedBox.square(
                  dimension: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.sync),
        ),
      ],
      builder: (context, wide) => _content(
        wide: wide,
        users: users,
        count: count,
        firestoreCopy: source == 'firestore',
        emptyText: !hasSnapshot
            ? 'Aucune copie locale des comptes.\n'
                  'Connectez-vous à Internet pour la télécharger.'
            : all.isEmpty
            ? 'Aucun compte'
            : 'Aucun compte trouvé',
      ),
    );
  }

  Widget _content({
    required bool wide,
    required List<Json> users,
    required int Function(String?) count,
    required bool firestoreCopy,
    required String emptyText,
  }) {
    final header = Padding(
      padding: EdgeInsets.fromLTRB(wide ? 24 : 16, 16, wide ? 24 : 16, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const Expanded(
                child: Text(
                  'Gestion des utilisateurs',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
                ),
              ),
              FilledButton.icon(
                onPressed: _add,
                icon: const Icon(Icons.add, size: 18),
                label: Text(wide ? 'Ajouter un utilisateur' : 'Ajouter'),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            alignment: WrapAlignment.spaceBetween,
            children: [
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final (index, tab) in _tabs.indexed)
                    if (tab.status != 'pending' || count('pending') > 0)
                      ChoiceChip(
                        label: Text('${tab.label} (${count(tab.status)})'),
                        selected: _tab == index,
                        onSelected: (_) => setState(() => _tab = index),
                      ),
                ],
              ),
              SizedBox(
                width: wide ? 280 : double.infinity,
                child: TextField(
                  controller: _search,
                  onChanged: (value) => setState(() => _query = value),
                  decoration: const InputDecoration(
                    hintText: 'Rechercher…',
                    prefixIcon: Icon(Icons.search),
                    isDense: true,
                  ),
                ),
              ),
            ],
          ),
          if (firestoreCopy) ...[
            const SizedBox(height: 12),
            const _Notice(
              icon: Icons.cloud_queue,
              text:
                  'Base principale indisponible : liste issue de la copie '
                  'Firebase. Vos modifications seront appliquées à son retour.',
            ),
          ],
        ],
      ),
    );

    final list = users.isEmpty
        ? AdminEmptyMessage(icon: Icons.person_search_outlined, text: emptyText)
        : wide
        ? _UsersTable(users: users, onToggle: _toggle, onDetails: _details)
        : ListView.separated(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            itemCount: users.length,
            separatorBuilder: (_, _) => const SizedBox(height: 8),
            itemBuilder: (context, index) {
              final user = users[index];
              return _UserCard(
                user: user,
                onToggle: (activate) => _toggle(user, activate),
                onDetails: () => _details(user),
              );
            },
          );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(color: AppColors.surface, child: header),
        const Divider(height: 1),
        const SizedBox(height: 12),
        Expanded(
          child: RefreshIndicator(
            onRefresh: () => _refresh(manual: true),
            // Noms, emails… sélectionnables pour pouvoir les copier.
            child: SelectionArea(child: list),
          ),
        ),
      ],
    );
  }
}

// ---------- Tableau (grand écran) ----------

class _UsersTable extends StatelessWidget {
  const _UsersTable({
    required this.users,
    required this.onToggle,
    required this.onDetails,
  });

  final List<Json> users;
  final void Function(Json user, bool activate) onToggle;
  final void Function(Json user) onDetails;

  static const _headerStyle = TextStyle(
    color: AppColors.textMuted,
    fontSize: 12,
    fontWeight: FontWeight.w600,
  );

  Widget _row({
    required Widget name,
    required Widget email,
    required Widget role,
    required Widget status,
    required Widget actions,
    required Widget more,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: Row(
        children: [
          Expanded(flex: 3, child: name),
          Expanded(flex: 3, child: email),
          Expanded(flex: 2, child: role),
          Expanded(flex: 2, child: status),
          SizedBox(width: 72, child: actions),
          SizedBox(width: 48, child: more),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
      children: [
        Card(
          margin: EdgeInsets.zero,
          clipBehavior: Clip.antiAlias,
          child: Column(
            children: [
              Container(
                color: AppColors.background,
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: _row(
                  name: const Text('Nom', style: _headerStyle),
                  email: const Text('Email', style: _headerStyle),
                  role: const Text('Rôle', style: _headerStyle),
                  status: const Text('Statut', style: _headerStyle),
                  actions: const Text('Actions', style: _headerStyle),
                  more: const SizedBox(),
                ),
              ),
              for (final (index, user) in users.indexed) ...[
                if (index > 0) const Divider(height: 1),
                _row(
                  name: Row(
                    children: [
                      const Icon(
                        Icons.person_outline,
                        size: 20,
                        color: AppColors.primary,
                      ),
                      const SizedBox(width: 8),
                      Flexible(
                        child: Text(
                          user['name'] as String? ?? '',
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontWeight: FontWeight.w600),
                        ),
                      ),
                    ],
                  ),
                  email: Text(
                    user['email'] as String? ?? '',
                    overflow: TextOverflow.ellipsis,
                  ),
                  role: Text(roleLabel(user), overflow: TextOverflow.ellipsis),
                  status: Align(
                    alignment: Alignment.centerLeft,
                    child: _StatusBadges(user: user),
                  ),
                  actions: Align(
                    alignment: Alignment.centerLeft,
                    child: _StatusSwitch(
                      user: user,
                      onToggle: (activate) => onToggle(user, activate),
                    ),
                  ),
                  more: _MoreMenu(
                    user: user,
                    onToggle: (activate) => onToggle(user, activate),
                    onDetails: () => onDetails(user),
                  ),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

// ---------- Carte (téléphone) ----------

class _UserCard extends StatelessWidget {
  const _UserCard({
    required this.user,
    required this.onToggle,
    required this.onDetails,
  });

  final Json user;
  final ValueChanged<bool> onToggle;
  final VoidCallback onDetails;

  @override
  Widget build(BuildContext context) {
    final name = user['name'] as String? ?? '';
    final reason = user['status_reason'] as String?;

    return Card(
      margin: EdgeInsets.zero,
      child: InkWell(
        borderRadius: BorderRadius.circular(AppTheme.radius),
        onTap: onDetails,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
          child: Row(
            children: [
              CircleAvatar(
                backgroundColor: AppColors.primarySoft,
                foregroundColor: AppColors.primary,
                child: Text(
                  name.isEmpty ? '?' : name[0].toUpperCase(),
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      name,
                      style: const TextStyle(fontWeight: FontWeight.w600),
                      overflow: TextOverflow.ellipsis,
                    ),
                    Text(
                      user['email'] as String? ?? '',
                      style: const TextStyle(
                        color: AppColors.textMuted,
                        fontSize: 13,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 6),
                    Wrap(
                      spacing: 6,
                      runSpacing: 4,
                      children: [
                        AdminBadge(
                          roleLabel(user),
                          AppColors.primarySoft,
                          AppColors.primary,
                        ),
                        _StatusBadges(user: user),
                      ],
                    ),
                    if (effectiveStatus(user) == 'suspended' &&
                        reason != null) ...[
                      const SizedBox(height: 4),
                      Text(
                        'Motif : $reason',
                        style: const TextStyle(
                          color: AppColors.textMuted,
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              _StatusSwitch(user: user, onToggle: onToggle),
            ],
          ),
        ),
      ),
    );
  }
}

// ---------- Éléments communs ----------

/// Libellé de l'acteur (Particulier, Commerçant…), sinon du rôle.
String roleLabel(Json user) =>
    user['actor_label'] as String? ??
    switch (user['role']) {
      'admin' => 'Administrateur',
      'association' => 'Association',
      'donor' => 'Donateur',
      _ => 'Bénéficiaire',
    };

/// Un compte en attente d'envoi (statut ou création) n'est pas modifiable.
bool _locked(Json user) =>
    user['pending_create'] == true || user['pending_status'] != null;

bool _canToggle(Json user) =>
    user['role'] != 'admin' &&
    user['id'] != null &&
    effectiveStatus(user) != 'pending';

class _StatusSwitch extends StatelessWidget {
  const _StatusSwitch({required this.user, required this.onToggle});

  final Json user;
  final ValueChanged<bool> onToggle;

  @override
  Widget build(BuildContext context) {
    if (!_canToggle(user)) return const SizedBox(width: 48);
    return Switch(
      value: effectiveStatus(user) == 'active',
      onChanged: _locked(user) ? null : onToggle,
    );
  }
}

class _StatusBadges extends StatelessWidget {
  const _StatusBadges({required this.user});

  final Json user;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 6,
      runSpacing: 4,
      children: [
        switch (effectiveStatus(user)) {
          'active' => const AdminBadge(
            'Actif',
            AppColors.primarySoft,
            AppColors.primary,
          ),
          'pending' => const AdminBadge(
            'Non activé',
            AppColors.accentSoft,
            AppColors.accent,
          ),
          _ => const AdminBadge(
            'Désactivé',
            Color(0xFFFDE7E7),
            AppColors.danger,
          ),
        },
        if (_locked(user))
          const AdminBadge(
            'En attente d’envoi',
            AppColors.accentSoft,
            AppColors.accent,
          ),
      ],
    );
  }
}

class _MoreMenu extends StatelessWidget {
  const _MoreMenu({
    required this.user,
    required this.onToggle,
    required this.onDetails,
  });

  final Json user;
  final ValueChanged<bool> onToggle;
  final VoidCallback onDetails;

  @override
  Widget build(BuildContext context) {
    final active = effectiveStatus(user) == 'active';
    return PopupMenuButton<String>(
      tooltip: 'Plus d’actions',
      icon: const Icon(Icons.more_horiz),
      onSelected: (value) => switch (value) {
        'details' => onDetails(),
        'message' => context.push(AppRoutes.conversation(user['id'] as int)),
        _ => onToggle(!active),
      },
      itemBuilder: (context) => [
        const PopupMenuItem(value: 'details', child: Text('Détails')),
        if (user['id'] != null && user['role'] != 'admin')
          const PopupMenuItem(
            value: 'message',
            child: Text('Envoyer un message'),
          ),
        if (_canToggle(user) && !_locked(user))
          PopupMenuItem(
            value: 'toggle',
            child: Text(active ? 'Désactiver' : 'Réactiver'),
          ),
      ],
    );
  }
}

class _Notice extends StatelessWidget {
  const _Notice({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: AppColors.accentSoft,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          Icon(icon, size: 18, color: AppColors.accent),
          const SizedBox(width: 8),
          Expanded(child: Text(text, style: const TextStyle(fontSize: 13))),
        ],
      ),
    );
  }
}

// ---------- Dialogues ----------

class _UserDetailsDialog extends StatelessWidget {
  const _UserDetailsDialog({required this.user});

  final Json user;

  @override
  Widget build(BuildContext context) {
    final reason = user['status_reason'] as String?;
    final rows = [
      ('E-mail', user['email'] as String? ?? '—'),
      ('Téléphone', user['phone'] as String? ?? '—'),
      ('Rôle', roleLabel(user)),
      ('Inscrit le', formatAdminDate(user['created_at'])),
      if (effectiveStatus(user) == 'suspended' && reason != null)
        ('Motif de désactivation', reason),
    ];
    return AlertDialog(
      title: Text(user['name'] as String? ?? ''),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _StatusBadges(user: user),
          const SizedBox(height: 12),
          for (final (label, value) in rows)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    label,
                    style: const TextStyle(
                      color: AppColors.textMuted,
                      fontSize: 12,
                    ),
                  ),
                  SelectableText(value),
                ],
              ),
            ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Fermer'),
        ),
      ],
    );
  }
}

class _DeactivateDialog extends StatefulWidget {
  const _DeactivateDialog({required this.name});

  final String name;

  @override
  State<_DeactivateDialog> createState() => _DeactivateDialogState();
}

class _DeactivateDialogState extends State<_DeactivateDialog> {
  final _form = GlobalKey<FormState>();
  final _reason = TextEditingController();

  @override
  void dispose() {
    _reason.dispose();
    super.dispose();
  }

  void _submit() {
    if (_form.currentState!.validate()) {
      Navigator.of(context).pop(_reason.text.trim());
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Désactiver le compte ?'),
      content: Form(
        key: _form,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '${widget.name} ne pourra plus se connecter. '
              'Le motif lui sera communiqué.',
            ),
            const SizedBox(height: 16),
            TextFormField(
              controller: _reason,
              autofocus: true,
              maxLength: 255,
              maxLines: 2,
              decoration: const InputDecoration(
                labelText: 'Motif',
                hintText: 'Ex. : comportement abusif signalé',
              ),
              validator: requiredField('Motif obligatoire'),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Annuler'),
        ),
        FilledButton(
          style: FilledButton.styleFrom(backgroundColor: AppColors.danger),
          onPressed: _submit,
          child: const Text('Désactiver'),
        ),
      ],
    );
  }
}

/// Ajout d'un compte ; renvoie le résultat de l'envoi (ou de la mise en file).
class _AddUserDialog extends ConsumerStatefulWidget {
  const _AddUserDialog();

  @override
  ConsumerState<_AddUserDialog> createState() => _AddUserDialogState();
}

class _AddUserDialogState extends ConsumerState<_AddUserDialog> {
  final _form = GlobalKey<FormState>();
  final _firstName = TextEditingController();
  final _lastName = TextEditingController();
  final _email = TextEditingController();
  final _phone = TextEditingController();
  final _password = TextEditingController();
  int? _actorId;
  var _saving = false;

  static final _phonePattern = RegExp(r'^\+?[0-9 ]{8,20}$');

  @override
  void dispose() {
    for (final controller in [
      _firstName,
      _lastName,
      _email,
      _phone,
      _password,
    ]) {
      controller.dispose();
    }
    super.dispose();
  }

  Future<void> _submit(List<Json> actors) async {
    if (!_form.currentState!.validate()) return;
    final email = _email.text.trim().toLowerCase();
    final taken = ref
        .read(adminUsersProvider)
        .any((user) => (user['email'] as String?)?.toLowerCase() == email);
    if (taken) {
      showMessage(
        context,
        'Un compte existe déjà avec cet e-mail',
        error: true,
      );
      return;
    }

    setState(() => _saving = true);
    final phone = _phone.text.trim();
    final result = await ref
        .read(adminRepositoryProvider)
        .createUser(
          firstName: _firstName.text.trim(),
          lastName: _lastName.text.trim(),
          email: email,
          phone: phone.isEmpty ? null : phone,
          actor: actors.firstWhere((actor) => actor['id'] == _actorId),
          password: _password.text,
        );
    if (!mounted) return;
    setState(() => _saving = false);
    if (result is Rejected) {
      showMessage(context, result.message, error: true);
      return;
    }
    Navigator.of(context).pop(result);
  }

  @override
  Widget build(BuildContext context) {
    // Particulier, commerçant, restaurateur ou administrateur : une
    // association s'inscrit elle-même (informations à faire valider).
    final actors = [
      for (final actor in ref.watch(actorsProvider))
        if (actor['active'] != false &&
            actor['active'] != 0 &&
            actor['permission_role'] != 'association')
          actor,
    ];

    return AlertDialog(
      title: const Text('Ajouter un utilisateur'),
      content: SizedBox(
        width: 420,
        child: Form(
          key: _form,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (actors.isEmpty)
                  const _Notice(
                    icon: Icons.cloud_off,
                    text:
                        'Liste des rôles indisponible : connectez-vous à '
                        'Internet une première fois pour la télécharger.',
                  ),
                TextFormField(
                  controller: _firstName,
                  autofocus: true,
                  textCapitalization: TextCapitalization.words,
                  decoration: const InputDecoration(labelText: 'Prénom'),
                  validator: _minLength('Prénom'),
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _lastName,
                  textCapitalization: TextCapitalization.words,
                  decoration: const InputDecoration(labelText: 'Nom'),
                  validator: _minLength('Nom'),
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _email,
                  keyboardType: TextInputType.emailAddress,
                  decoration: const InputDecoration(labelText: 'E-mail'),
                  validator: validateEmail,
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _phone,
                  keyboardType: TextInputType.phone,
                  decoration: const InputDecoration(
                    labelText: 'Téléphone (facultatif)',
                  ),
                  validator: (value) {
                    final phone = value?.trim() ?? '';
                    return phone.isEmpty || _phonePattern.hasMatch(phone)
                        ? null
                        : 'Numéro de téléphone invalide';
                  },
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<int>(
                  initialValue: _actorId,
                  decoration: const InputDecoration(labelText: 'Rôle'),
                  items: [
                    for (final actor in actors)
                      DropdownMenuItem(
                        value: actor['id'] as int,
                        child: Text(actor['label'] as String),
                      ),
                  ],
                  onChanged: (value) => setState(() => _actorId = value),
                  validator: (value) =>
                      value == null ? 'Rôle obligatoire' : null,
                ),
                const SizedBox(height: 12),
                PasswordField(
                  controller: _password,
                  hint: '',
                  label: 'Mot de passe provisoire',
                  helper:
                      'À communiquer à l’utilisateur ; modifiable via '
                      '« Mot de passe oublié ».',
                  validator: validatePassword,
                ),
              ],
            ),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.of(context).pop(),
          child: const Text('Annuler'),
        ),
        FilledButton(
          onPressed: _saving || actors.isEmpty ? null : () => _submit(actors),
          child: _saving
              ? const SizedBox.square(
                  dimension: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('Ajouter'),
        ),
      ],
    );
  }

  static String? Function(String?) _minLength(String field) => (value) {
    final text = value?.trim() ?? '';
    if (text.isEmpty) return '$field obligatoire';
    if (text.length < 2) return '2 caractères minimum';
    return null;
  };
}
