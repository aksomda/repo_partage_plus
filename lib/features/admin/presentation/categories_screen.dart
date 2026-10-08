import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:repo_partage_plus/core/offline/offline_data.dart';
import 'package:repo_partage_plus/core/router/app_routes.dart';
import 'package:repo_partage_plus/core/theme/app_theme.dart';
import 'package:repo_partage_plus/features/admin/data/admin_repository.dart';
import 'package:repo_partage_plus/features/admin/presentation/widgets/admin_forms.dart';
import 'package:repo_partage_plus/features/admin/presentation/widgets/admin_shell.dart';
import 'package:repo_partage_plus/features/auth/presentation/widgets/auth_widgets.dart';
import 'package:repo_partage_plus/features/offers/data/offers_repository.dart';
import 'package:repo_partage_plus/features/offers/presentation/widgets/offer_widgets.dart';

/// Catégories de produits proposées à la publication (nom et icône). Une
/// catégorie encore utilisée par des offres ne peut pas être supprimée.
class CategoriesScreen extends ConsumerWidget {
  const CategoriesScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final categories = ref.watch(categoriesProvider);
    final waiting = {
      for (final action in ref.watch(waitingActionsProvider))
        if (action.kind.startsWith('category.') && action.targetId != null)
          action.targetId,
    };
    final creating = ref
        .watch(waitingActionsProvider)
        .where((a) => a.kind == 'category.save' && a.targetId == null)
        .map((a) => a.body?['name'] as String? ?? '')
        .toList();

    return AdminShell(
      title: 'Catégories',
      current: AppRoutes.adminManage,
      actions: [
        IconButton(
          tooltip: 'Ajouter une catégorie',
          icon: const Icon(Icons.add),
          onPressed: () => showAdminSheet<void>(context, const _CategoryForm()),
        ),
        const AdminSyncButton(),
      ],
      builder: (context, wide) => RefreshIndicator(
        onRefresh: () => refreshAdminData(context, ref),
        child: ListView(
          padding: EdgeInsets.all(wide ? 24 : 16),
          children: [
            const Text(
              'Catégories proposées aux publieurs. Le facteur d’impact de '
              'chaque catégorie se règle dans « Facteurs d’impact ».',
              style: TextStyle(color: AppColors.textMuted),
            ),
            const SizedBox(height: 16),
            for (final name in creating)
              _CategoryTile(
                category: {'name': name},
                waiting: true,
                onTap: null,
              ),
            if (categories.isEmpty && creating.isEmpty)
              const Padding(
                padding: EdgeInsets.all(32),
                child: Text(
                  'Aucune catégorie synchronisée : tirez vers le bas pour '
                  'actualiser.',
                  textAlign: TextAlign.center,
                ),
              ),
            for (final category in categories)
              _CategoryTile(
                category: category,
                waiting: waiting.contains(category['id']),
                onTap: () => showAdminSheet<void>(
                  context,
                  _CategoryForm(category: category),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _CategoryTile extends StatelessWidget {
  const _CategoryTile({
    required this.category,
    required this.waiting,
    required this.onTap,
  });

  final Json category;
  final bool waiting;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final co2 = category['co2_kg_per_kg'] as num?;
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: ListTile(
        onTap: onTap,
        leading: CircleAvatar(
          backgroundColor: categoryColor(category['id']),
          foregroundColor: AppColors.text,
          child: Icon(categoryIcon(category['icon'])),
        ),
        title: Text(
          category['name'] as String? ?? '',
          style: const TextStyle(fontWeight: FontWeight.w600),
        ),
        subtitle: Text(
          co2 == null
              ? 'Pas de facteur d’impact'
              : '${co2.toStringAsFixed(1)} kg CO₂ évités par kg',
        ),
        trailing: waiting
            ? const AdminBadge(
                'En attente d’envoi',
                AppColors.accentSoft,
                AppColors.accent,
              )
            : onTap == null
            ? null
            : const Icon(Icons.edit_outlined, color: AppColors.textMuted),
      ),
    );
  }
}

class _CategoryForm extends ConsumerStatefulWidget {
  const _CategoryForm({this.category});

  /// null : création.
  final Json? category;

  @override
  ConsumerState<_CategoryForm> createState() => _CategoryFormState();
}

class _CategoryFormState extends ConsumerState<_CategoryForm> {
  final _form = GlobalKey<FormState>();
  late final _name = TextEditingController(text: widget.category?['name']);
  late String? _icon = widget.category?['icon'] as String?;
  var _loading = false;

  bool get _creating => widget.category == null;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_form.currentState!.validate()) return;
    setState(() => _loading = true);
    final result = await ref
        .read(adminRepositoryProvider)
        .saveCategory(
          id: widget.category?['id'] as int?,
          name: _name.text.trim(),
          icon: _icon,
        );
    if (!mounted) return;
    setState(() => _loading = false);
    if (showAdminResult(context, result, sent: 'Catégorie enregistrée')) {
      Navigator.of(context).pop();
    }
  }

  Future<void> _delete() async {
    final name = widget.category!['name'] as String;
    final confirmed = await confirmAdminDelete(
      context,
      title: 'Supprimer « $name » ?',
      message:
          'Impossible si des offres l’utilisent encore. Son facteur '
          'd’impact est supprimé avec elle.',
    );
    if (!confirmed || !mounted) return;
    final result = await ref
        .read(adminRepositoryProvider)
        .deleteCategory(widget.category!['id'] as int, name);
    if (!mounted) return;
    if (showAdminResult(context, result, sent: '« $name » supprimée')) {
      Navigator.of(context).pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Form(
      key: _form,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          AdminSheetTitle(
            _creating ? 'Nouvelle catégorie' : 'Modifier la catégorie',
          ),
          LabeledField(
            label: 'Nom',
            child: TextFormField(
              controller: _name,
              autofocus: _creating,
              maxLength: 80,
              textCapitalization: TextCapitalization.sentences,
              decoration: const InputDecoration(hintText: 'Ex. : Poisson'),
              validator: (value) => (value?.trim().length ?? 0) < 2
                  ? '2 caractères minimum'
                  : null,
            ),
          ),
          LabeledField(
            label: 'Icône',
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final entry in categoryIconChoices.entries)
                  ChoiceChip(
                    label: Icon(
                      entry.value,
                      size: 20,
                      color: _icon == entry.key ? Colors.white : AppColors.text,
                    ),
                    selected: _icon == entry.key,
                    tooltip: entry.key,
                    onSelected: (_) => setState(() => _icon = entry.key),
                  ),
              ],
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
              style: TextButton.styleFrom(foregroundColor: AppColors.danger),
              onPressed: _delete,
              icon: const Icon(Icons.delete_outline),
              label: const Text('Supprimer'),
            ),
          ],
        ],
      ),
    );
  }
}
