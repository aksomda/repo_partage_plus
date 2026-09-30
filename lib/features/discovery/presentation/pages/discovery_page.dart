import 'package:flutter/material.dart';

import '../../../offers/domain/entities/offer.dart';
import '../../../offers/presentation/pages/offer_detail_page.dart';
import '../../../offers/presentation/widgets/offer_card.dart';
import '../../data/mock_offers.dart';
import '../../domain/offer_filters.dart';

class DiscoveryPage extends StatefulWidget {
  const DiscoveryPage({super.key});

  @override
  State<DiscoveryPage> createState() => _DiscoveryPageState();
}

class _DiscoveryPageState extends State<DiscoveryPage> {
  final TextEditingController _searchController = TextEditingController();

  OfferFilters _filters = const OfferFilters();

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final offers = _filterOffers();

    return Scaffold(
      appBar: AppBar(title: const Text('Découvrir')),
      body: Column(
        children: [
          _buildSearchBar(),
          _buildFilterBar(),
          Expanded(child: _buildOfferList(offers)),
        ],
      ),
    );
  }

  Widget _buildSearchBar() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
      child: TextField(
        controller: _searchController,
        onChanged: (_) {
          setState(() {});
        },
        decoration: InputDecoration(
          hintText: 'Rechercher une offre',
          prefixIcon: const Icon(Icons.search),
          suffixIcon: _searchController.text.isEmpty
              ? null
              : IconButton(
                  onPressed: () {
                    _searchController.clear();
                    setState(() {});
                  },
                  icon: const Icon(Icons.clear),
                ),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(14),
            borderSide: BorderSide.none,
          ),
          filled: true,
          fillColor: Colors.grey.shade100,
        ),
      ),
    );
  }

  Widget _buildFilterBar() {
    return SizedBox(
      height: 54,
      child: ListView(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        scrollDirection: Axis.horizontal,
        children: [
          FilterChip(
            label: const Text('Filtres'),
            avatar: const Icon(Icons.tune, size: 18),
            selected: _filters.hasActiveFilters,
            onSelected: (_) {
              _showFilters();
            },
          ),
          const SizedBox(width: 8),
          _CategoryChip(
            label: 'Boulangerie',
            selected: _filters.category == 'Boulangerie',
            onTap: () {
              _toggleCategory('Boulangerie');
            },
          ),
          const SizedBox(width: 8),
          _CategoryChip(
            label: 'Fruits/lég.',
            selected: _filters.category == 'Fruits & légumes',
            onTap: () {
              _toggleCategory('Fruits & légumes');
            },
          ),
          const SizedBox(width: 8),
          _CategoryChip(
            label: 'Plats',
            selected: _filters.category == 'Plats cuisinés',
            onTap: () {
              _toggleCategory('Plats cuisinés');
            },
          ),
          const SizedBox(width: 8),
          FilterChip(
            label: const Text('Gratuit'),
            selected: _filters.type == OfferType.free,
            onSelected: (_) {
              setState(() {
                final isSelected = _filters.type == OfferType.free;

                _filters = _filters.copyWith(
                  type: isSelected ? null : OfferType.free,
                  clearType: isSelected,
                );
              });
            },
          ),
          const SizedBox(width: 8),
          FilterChip(
            label: const Text('Retrait ce soir'),
            selected: _filters.onlyUrgent,
            onSelected: (value) {
              setState(() {
                _filters = _filters.copyWith(onlyUrgent: value);
              });
            },
          ),
        ],
      ),
    );
  }

  Widget _buildOfferList(List<Offer> offers) {
    if (offers.isEmpty) {
      return const Center(
        child: Text(
          'Aucune offre ne correspond à votre recherche.',
          textAlign: TextAlign.center,
        ),
      );
    }

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
      children: [
        Text(
          '${offers.length} offre(s) disponible(s)',
          style: Theme.of(
            context,
          ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 12),
        ...offers.map(
          (offer) => OfferCard(
            offer: offer,
            onTap: () {
              _openOfferDetail(offer);
            },
          ),
        ),
      ],
    );
  }

  List<Offer> _filterOffers() {
    final query = _searchController.text.trim().toLowerCase();

    return mockOffers.where((offer) {
      final matchesSearch =
          query.isEmpty ||
          offer.title.toLowerCase().contains(query) ||
          offer.category.toLowerCase().contains(query) ||
          offer.merchantName.toLowerCase().contains(query);

      final matchesCategory =
          _filters.category == null || offer.category == _filters.category;

      final matchesType = _filters.type == null || offer.type == _filters.type;

      final matchesDistance =
          _filters.maxDistanceKm == null ||
          offer.distanceKm <= _filters.maxDistanceKm!;

      final matchesAvailability = !_filters.onlyAvailable || offer.isAvailable;

      final matchesUrgency =
          !_filters.onlyUrgent || offer.wasteRisk == WasteRisk.high;

      return matchesSearch &&
          matchesCategory &&
          matchesType &&
          matchesDistance &&
          matchesAvailability &&
          matchesUrgency;
    }).toList();
  }

  void _toggleCategory(String category) {
    setState(() {
      final isSelected = _filters.category == category;

      _filters = _filters.copyWith(
        category: isSelected ? null : category,
        clearCategory: isSelected,
      );
    });
  }

  Future<void> _showFilters() async {
    OfferFilters temporaryFilters = _filters;

    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setModalState) {
            return Padding(
              padding: EdgeInsets.only(
                left: 20,
                top: 20,
                right: 20,
                bottom: MediaQuery.of(context).viewInsets.bottom + 24,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Text(
                        'Filtrer les offres',
                        style: Theme.of(context).textTheme.titleLarge?.copyWith(
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const Spacer(),
                      TextButton(
                        onPressed: () {
                          temporaryFilters = temporaryFilters.reset();
                          setModalState(() {});
                        },
                        child: const Text('Réinitialiser'),
                      ),
                    ],
                  ),
                  const SizedBox(height: 18),
                  const Text(
                    'Catégorie',
                    style: TextStyle(fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children:
                        [
                          'Boulangerie',
                          'Fruits & légumes',
                          'Plats cuisinés',
                          'Produits laitiers',
                        ].map((category) {
                          return ChoiceChip(
                            label: Text(category),
                            selected: temporaryFilters.category == category,
                            onSelected: (_) {
                              final isSelected =
                                  temporaryFilters.category == category;

                              temporaryFilters = temporaryFilters.copyWith(
                                category: isSelected ? null : category,
                                clearCategory: isSelected,
                              );

                              setModalState(() {});
                            },
                          );
                        }).toList(),
                  ),
                  const SizedBox(height: 20),
                  const Text(
                    'Type d’offre',
                    style: TextStyle(fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    children: [
                      ChoiceChip(
                        label: const Text('Gratuit'),
                        selected: temporaryFilters.type == OfferType.free,
                        onSelected: (_) {
                          final isSelected =
                              temporaryFilters.type == OfferType.free;

                          temporaryFilters = temporaryFilters.copyWith(
                            type: isSelected ? null : OfferType.free,
                            clearType: isSelected,
                          );

                          setModalState(() {});
                        },
                      ),
                      ChoiceChip(
                        label: const Text('Prix réduit'),
                        selected: temporaryFilters.type == OfferType.discounted,
                        onSelected: (_) {
                          final isSelected =
                              temporaryFilters.type == OfferType.discounted;

                          temporaryFilters = temporaryFilters.copyWith(
                            type: isSelected ? null : OfferType.discounted,
                            clearType: isSelected,
                          );

                          setModalState(() {});
                        },
                      ),
                    ],
                  ),
                  const SizedBox(height: 20),
                  const Text(
                    'Distance maximale',
                    style: TextStyle(fontWeight: FontWeight.bold),
                  ),
                  DropdownButton<double?>(
                    value: temporaryFilters.maxDistanceKm,
                    isExpanded: true,
                    hint: const Text('Toutes les distances'),
                    items: const [
                      DropdownMenuItem<double?>(
                        value: null,
                        child: Text('Toutes les distances'),
                      ),
                      DropdownMenuItem<double?>(value: 1, child: Text('1 km')),
                      DropdownMenuItem<double?>(value: 3, child: Text('3 km')),
                      DropdownMenuItem<double?>(value: 5, child: Text('5 km')),
                      DropdownMenuItem<double?>(
                        value: 10,
                        child: Text('10 km'),
                      ),
                    ],
                    onChanged: (value) {
                      temporaryFilters = temporaryFilters.copyWith(
                        maxDistanceKm: value,
                        clearMaxDistance: value == null,
                      );

                      setModalState(() {});
                    },
                  ),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Offres à sauver rapidement'),
                    value: temporaryFilters.onlyUrgent,
                    onChanged: (value) {
                      temporaryFilters = temporaryFilters.copyWith(
                        onlyUrgent: value,
                      );

                      setModalState(() {});
                    },
                  ),
                  const SizedBox(height: 16),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton(
                      onPressed: () {
                        setState(() {
                          _filters = temporaryFilters;
                        });

                        Navigator.pop(context);
                      },
                      child: const Text('Appliquer les filtres'),
                    ),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  void _openOfferDetail(Offer offer) {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => OfferDetailPage(offer: offer)),
    );
  }
}

class _CategoryChip extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;

  const _CategoryChip({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return FilterChip(
      label: Text(label),
      selected: selected,
      onSelected: (_) {
        onTap();
      },
    );
  }
}
