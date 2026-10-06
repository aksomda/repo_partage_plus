import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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

/// Facteurs d'impact par catégorie : kg de CO₂ évités et repas équivalents
/// par kg de nourriture sauvée. Ils servent au calcul de l'impact (compteurs
/// et graphiques) ; une catégorie sans facteur compte 0 kg de CO₂.
class FactorsScreen extends ConsumerWidget {
  const FactorsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final categories = ref.watch(categoriesProvider);
    final factors = {
      for (final factor in ref.watch(factorsProvider))
        factor['category_id']: factor,
    };
    final waiting = {
      for (final action in ref.watch(waitingActionsProvider))
        if (action.kind.startsWith('factor.'))
          action.body?['category_id'] ?? action.targetId,
    };

    return AdminShell(
      title: 'Facteurs d’impact',
      current: AppRoutes.adminManage,
      actions: const [AdminSyncButton()],
      builder: (context, wide) => RefreshIndicator(
        onRefresh: () => refreshAdminData(context, ref),
        child: ListView(
          padding: EdgeInsets.all(wide ? 24 : 16),
          children: [
            const Text(
              'Pour chaque kg de nourriture retiré : CO₂ évité et nombre de '
              'repas équivalents. Indiquez la source des valeurs (ADEME, FAO…).',
              style: TextStyle(color: AppColors.textMuted),
            ),
            const SizedBox(height: 16),
            if (categories.isEmpty)
              const Padding(
                padding: EdgeInsets.all(32),
                child: Text(
                  'Aucune catégorie synchronisée : tirez vers le bas pour '
                  'actualiser.',
                  textAlign: TextAlign.center,
                ),
              ),
            for (final category in categories)
              _FactorTile(
                category: category,
                factor: factors[category['id']],
                waiting:
                    waiting.contains(category['id']) ||
                    waiting.contains(factors[category['id']]?['id']),
              ),
          ],
        ),
      ),
    );
  }
}

class _FactorTile extends StatelessWidget {
  const _FactorTile({
    required this.category,
    required this.factor,
    required this.waiting,
  });

  final Json category;
  final Json? factor;
  final bool waiting;

  @override
  Widget build(BuildContext context) {
    final f = factor;
    String number(Object? value) =>
        (value as num?)?.toStringAsFixed(2).replaceAll('.', ',') ?? '—';

    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: ListTile(
        onTap: () => showAdminSheet<void>(
          context,
          _FactorForm(category: category, factor: f),
        ),
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
          f == null
              ? 'Aucun facteur : impact CO₂ non calculé'
              : '${number(f['co2_kg_per_kg'])} kg CO₂/kg · '
                    '${number(f['meals_per_kg'])} repas/kg'
                    '${f['source'] == null ? '' : '\nSource : ${f['source']}'}',
        ),
        isThreeLine: f?['source'] != null,
        trailing: waiting
            ? const AdminBadge(
                'En attente d’envoi',
                AppColors.accentSoft,
                AppColors.accent,
              )
            : Icon(
                f == null ? Icons.add_circle_outline : Icons.edit_outlined,
                color: f == null ? AppColors.accent : AppColors.textMuted,
              ),
      ),
    );
  }
}

class _FactorForm extends ConsumerStatefulWidget {
  const _FactorForm({required this.category, this.factor});

  final Json category;

  /// null : création.
  final Json? factor;

  @override
  ConsumerState<_FactorForm> createState() => _FactorFormState();
}

class _FactorFormState extends ConsumerState<_FactorForm> {
  final _form = GlobalKey<FormState>();
  late final _co2 = TextEditingController(
    text: _text(widget.factor?['co2_kg_per_kg']),
  );
  late final _meals = TextEditingController(
    text: _text(widget.factor?['meals_per_kg'] ?? 2.5),
  );
  late final _source = TextEditingController(text: widget.factor?['source']);
  var _loading = false;

  static String _text(Object? value) =>
      value == null ? '' : '$value'.replaceAll('.', ',');

  static double? _parse(String? value) =>
      double.tryParse((value ?? '').trim().replaceAll(',', '.'));

  @override
  void dispose() {
    for (final controller in [_co2, _meals, _source]) {
      controller.dispose();
    }
    super.dispose();
  }

  String? Function(String?) _range(double max) => (value) {
    final number = _parse(value);
    if (number == null) return 'Nombre attendu (ex. : 2,5)';
    if (number < 0 || number > max) return 'Entre 0 et $max';
    return null;
  };

  Future<void> _submit() async {
    if (!_form.currentState!.validate()) return;
    setState(() => _loading = true);
    final result = await ref
        .read(adminRepositoryProvider)
        .saveFactor(
          id: widget.factor?['id'] as int?,
          categoryId: widget.category['id'] as int,
          co2KgPerKg: _parse(_co2.text)!,
          mealsPerKg: _parse(_meals.text)!,
          source: _source.text.trim().isEmpty ? null : _source.text.trim(),
        );
    if (!mounted) return;
    setState(() => _loading = false);
    if (showAdminResult(context, result, sent: 'Facteur enregistré')) {
      Navigator.of(context).pop();
    }
  }

  Future<void> _delete() async {
    final confirmed = await confirmAdminDelete(
      context,
      title: 'Supprimer ce facteur ?',
      message:
          'Le CO₂ et les repas des retraits de « ${widget.category['name']} » '
          'ne seront plus comptés.',
    );
    if (!confirmed || !mounted) return;
    final result = await ref
        .read(adminRepositoryProvider)
        .deleteFactor(widget.factor!['id'] as int);
    if (!mounted) return;
    if (showAdminResult(context, result, sent: 'Facteur supprimé')) {
      Navigator.of(context).pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    final decimal = [FilteringTextInputFormatter.allow(RegExp(r'[0-9.,]'))];
    return Form(
      key: _form,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          AdminSheetTitle('Facteur : ${widget.category['name']}'),
          LabeledField(
            label: 'kg de CO₂ évités par kg sauvé',
            child: TextFormField(
              controller: _co2,
              autofocus: widget.factor == null,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              inputFormatters: decimal,
              decoration: const InputDecoration(hintText: 'Ex. : 2,5'),
              validator: _range(1000),
            ),
          ),
          LabeledField(
            label: 'Repas équivalents par kg',
            child: TextFormField(
              controller: _meals,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              inputFormatters: decimal,
              decoration: const InputDecoration(
                hintText: '2,5 (1 repas ≈ 400 g)',
              ),
              validator: _range(100),
            ),
          ),
          LabeledField(
            label: 'Source (facultatif)',
            child: TextFormField(
              controller: _source,
              maxLength: 255,
              decoration: const InputDecoration(
                hintText: 'Ex. : ADEME, Base Empreinte 2024',
              ),
            ),
          ),
          LoadingButton(
            label: 'Enregistrer',
            loading: _loading,
            onPressed: _submit,
          ),
          if (widget.factor != null) ...[
            const SizedBox(height: 8),
            TextButton.icon(
              style: TextButton.styleFrom(foregroundColor: AppColors.danger),
              onPressed: _delete,
              icon: const Icon(Icons.delete_outline),
              label: const Text('Supprimer le facteur'),
            ),
          ],
        ],
      ),
    );
  }
}
