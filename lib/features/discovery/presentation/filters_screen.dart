import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'package:repo_partage_plus/core/location/location.dart';
import 'package:repo_partage_plus/core/theme/app_theme.dart';
import 'package:repo_partage_plus/core/widgets/text_prompt_dialog.dart';
import 'package:repo_partage_plus/features/auth/presentation/widgets/auth_widgets.dart';
import 'package:repo_partage_plus/features/discovery/presentation/widgets/discovery_widgets.dart';
import 'package:repo_partage_plus/features/favorites/data/favorites.dart';
import 'package:repo_partage_plus/features/offers/data/offers_repository.dart';

/// Filtres et recherche (maquette) : catégorie, distance, prix, date limite,
/// tri, auteur, favoris et recherches enregistrées. Rien n'est appliqué
/// avant « Appliquer les filtres ».
class FiltersScreen extends ConsumerStatefulWidget {
  const FiltersScreen({super.key});

  @override
  ConsumerState<FiltersScreen> createState() => _FiltersScreenState();
}

class _FiltersScreenState extends ConsumerState<FiltersScreen> {
  late OfferFilters _draft = ref.read(offerFiltersProvider);

  void _set(OfferFilters filters) => setState(() => _draft = filters);

  void _apply() {
    ref.read(offerFiltersProvider.notifier).apply(_draft);
    context.pop();
  }

  @override
  Widget build(BuildContext context) {
    final hasOrigin = ref.watch(originProvider).place != null;
    final radiusIndex = searchRadii.indexOf(_draft.radiusKm);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Filtres'),
        actions: [
          TextButton(
            onPressed: () => _set(OfferFilters(text: _draft.text)),
            child: const Text('Réinitialiser'),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
        children: [
          const _Title('Catégorie'),
          CategoryCircles(filters: _draft, onApply: _set, wrap: true),
          const _Title('Distance'),
          if (!hasOrigin)
            const Text(
              'Position inconnue : choisissez un point de départ pour '
              'limiter la distance.',
              style: TextStyle(color: AppColors.textMuted),
            )
          else ...[
            Slider(
              value: radiusIndex.toDouble(),
              max: (searchRadii.length - 1).toDouble(),
              divisions: searchRadii.length - 1,
              label: radiusLabel(_draft.radiusKm),
              onChanged: (value) =>
                  _set(_draft.copyWith(radiusKm: searchRadii[value.round()])),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    radiusLabel(searchRadii.first),
                    style: const TextStyle(color: AppColors.textMuted),
                  ),
                  Text(
                    _draft.radiusKm.isFinite
                        ? 'Jusqu’à ${radiusLabel(_draft.radiusKm)}'
                        : 'Sans limite',
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                  const Text(
                    'Illimité',
                    style: TextStyle(color: AppColors.textMuted),
                  ),
                ],
              ),
            ),
          ],
          const _Title('Prix'),
          _Choices<PriceFilter>(
            values: PriceFilter.values,
            selected: _draft.price,
            label: (price) => price == PriceFilter.all ? 'Tous' : price.label,
            onSelected: (price) => _set(_draft.copyWith(price: price)),
          ),
          const _Title('Date limite de consommation'),
          _Choices<bool>(
            values: const [false, true],
            selected: _draft.urgentOnly,
            label: (urgent) => urgent ? 'Aujourd’hui ou demain' : 'Toutes',
            onSelected: (urgent) => _set(_draft.copyWith(urgentOnly: urgent)),
          ),
          const _Title('Trier par'),
          _Choices<OfferSort>(
            values: OfferSort.values,
            selected: _draft.sort,
            label: (sort) => sort.label,
            onSelected: (sort) => _set(_draft.copyWith(sort: sort)),
          ),
          const _Title('Publiées par'),
          _Choices<OfferOwner>(
            values: OfferOwner.values,
            selected: _draft.owner,
            label: (owner) => switch (owner) {
              OfferOwner.all => 'Tout le monde',
              OfferOwner.mine => 'Moi',
              OfferOwner.others => 'Les autres',
            },
            onSelected: (owner) => _set(_draft.copyWith(owner: owner)),
          ),
          const SizedBox(height: 8),
          _SavedSearches(filters: _draft, onApply: _set),
        ],
      ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
          child: FilledButton(
            onPressed: _apply,
            child: const Text('Appliquer les filtres'),
          ),
        ),
      ),
    );
  }
}

class _Title extends StatelessWidget {
  const _Title(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 20, bottom: 8),
      child: Text(
        text,
        style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15),
      ),
    );
  }
}

/// Choix unique en puces (maquette : « Toutes · Aujourd'hui · Demain »).
class _Choices<T> extends StatelessWidget {
  const _Choices({
    required this.values,
    required this.selected,
    required this.label,
    required this.onSelected,
  });

  final List<T> values;
  final T selected;
  final String Function(T) label;
  final ValueChanged<T> onSelected;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (final value in values)
          ChoiceChip(
            label: Text(label(value)),
            selected: value == selected,
            labelStyle: TextStyle(
              color: value == selected ? Colors.white : AppColors.text,
            ),
            onSelected: (_) => onSelected(value),
          ),
      ],
    );
  }
}

/// Favoris (sans compte aussi) : « offres favorites seulement », recherches
/// enregistrées (relancées d'un geste, supprimables par leur croix),
/// recherches suggérées, et enregistrement de la recherche en cours.
class _SavedSearches extends ConsumerWidget {
  const _SavedSearches({required this.filters, required this.onApply});

  final OfferFilters filters;
  final ValueChanged<OfferFilters> onApply;

  Future<void> _save(BuildContext context, WidgetRef ref) async {
    final categories = ref.read(categoriesProvider);
    final category = categories
        .where((c) => c['id'] == filters.categoryId)
        .firstOrNull;
    final suggested = [
      if (filters.text.trim().isNotEmpty) filters.text.trim(),
      if (category != null) category['name'],
      if (filters.price != PriceFilter.all) filters.price.label,
      if (filters.urgentOnly) 'urgent',
    ].join(' · ');
    final name = await showTextPrompt(
      context,
      title: 'Enregistrer la recherche',
      action: 'Enregistrer',
      hint: 'Nom (ex. : Pain du soir)',
      initial: suggested,
      maxLength: 40,
      emptyMessage: 'Donnez un nom à la recherche',
    );
    if (name == null) return;
    await ref
        .read(favoritesProvider.notifier)
        .saveSearch(
          SavedSearch(
            name: name,
            text: filters.text.trim(),
            categoryId: filters.categoryId,
            radiusKm: filters.radiusKm,
            price: filters.price,
            urgentOnly: filters.urgentOnly,
          ),
        );
    if (context.mounted) {
      showMessage(
        context,
        'Recherche « $name » enregistrée : vous serez prévenu des nouvelles '
        'offres correspondantes',
      );
    }
  }

  Future<void> _remove(
    BuildContext context,
    WidgetRef ref,
    SavedSearch search,
  ) async {
    final notifier = ref.read(favoritesProvider.notifier);
    await notifier.removeSearch(search.name);
    if (!context.mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text('Recherche « ${search.name} » supprimée'),
          action: SnackBarAction(
            label: 'Annuler',
            onPressed: () => notifier.saveSearch(search),
          ),
        ),
      );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final favorites = ref.watch(favoritesProvider);
    final count = favorites.offerIds.length;
    final saved = {
      for (final search in favorites.searches) search.name.toLowerCase(),
    };
    final suggestions = [
      for (final search in suggestedSearches)
        if (!saved.contains(search.name.toLowerCase())) search,
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const _Title('Favoris'),
        Card(
          child: SwitchListTile(
            secondary: Icon(
              filters.favoritesOnly ? Icons.favorite : Icons.favorite_border,
              color: AppColors.danger,
            ),
            title: Text('Mes offres favorites seulement ($count)'),
            subtitle: count == 0
                ? const Text('Touchez le cœur d’une offre pour l’ajouter')
                : null,
            value: filters.favoritesOnly,
            onChanged: (value) =>
                onApply(filters.copyWith(favoritesOnly: value)),
          ),
        ),
        if (favorites.searches.isNotEmpty || suggestions.isNotEmpty) ...[
          const _Title('Recherches'),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final search in favorites.searches)
                InputChip(
                  avatar: const Icon(Icons.bookmark_outline, size: 18),
                  label: Text(search.name),
                  tooltip: 'Relancer cette recherche',
                  deleteButtonTooltipMessage: 'Supprimer',
                  onPressed: () => onApply(filters.withSearch(search)),
                  onDeleted: () => _remove(context, ref, search),
                ),
              // Suggestions : recherches prêtes à l'emploi, même sans compte.
              for (final search in suggestions)
                ActionChip(
                  avatar: const Icon(Icons.lightbulb_outline, size: 18),
                  label: Text(search.name),
                  tooltip: 'Recherche suggérée',
                  onPressed: () => onApply(filters.withSearch(search)),
                ),
            ],
          ),
        ],
        if (filters.isSearch) ...[
          const SizedBox(height: 12),
          OutlinedButton.icon(
            onPressed: () => _save(context, ref),
            icon: const Icon(Icons.bookmark_add_outlined),
            label: const Text('Enregistrer la recherche'),
          ),
        ],
      ],
    );
  }
}
