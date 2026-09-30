import 'package:flutter/material.dart';

import '../../domain/entities/offer.dart';

class OfferDetailPage extends StatefulWidget {
  final Offer offer;

  const OfferDetailPage({super.key, required this.offer});

  @override
  State<OfferDetailPage> createState() => _OfferDetailPageState();
}

class _OfferDetailPageState extends State<OfferDetailPage> {
  PickupSlot? _selectedSlot;
  int _quantity = 1;

  Offer get offer => widget.offer;

  @override
  void initState() {
    super.initState();

    final availableSlots = offer.pickupSlots.where((slot) => !slot.isFull);

    if (availableSlots.isNotEmpty) {
      _selectedSlot = availableSlots.first;
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(title: const Text('Détail de l’offre')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _buildImagePlaceholder(),
          const SizedBox(height: 20),
          _buildHeader(theme),
          const SizedBox(height: 20),
          Text(offer.description, style: theme.textTheme.bodyLarge),
          const SizedBox(height: 20),
          _buildMerchantCard(),
          const SizedBox(height: 20),
          _buildPickupSlots(),
          const SizedBox(height: 20),
          _buildQuantitySelector(),
          if (offer.allergens.isNotEmpty) ...[
            const SizedBox(height: 20),
            _buildAllergens(),
          ],
          const SizedBox(height: 28),
          _buildReserveButton(),
        ],
      ),
    );
  }

  Widget _buildImagePlaceholder() {
    return Container(
      height: 220,
      decoration: BoxDecoration(
        color: const Color(0xFFE8F5E9),
        borderRadius: BorderRadius.circular(18),
      ),
      child: const Center(
        child: Icon(Icons.restaurant, size: 80, color: Colors.green),
      ),
    );
  }

  Widget _buildHeader(ThemeData theme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Chip(label: Text(offer.category)),
        const SizedBox(height: 10),
        Text(
          offer.title,
          style: theme.textTheme.headlineSmall?.copyWith(
            fontWeight: FontWeight.bold,
          ),
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Text(
              offer.formattedPrice,
              style: theme.textTheme.titleLarge?.copyWith(
                color: Colors.green.shade700,
                fontWeight: FontWeight.bold,
              ),
            ),
            if (offer.formattedOriginalPrice.isNotEmpty) ...[
              const SizedBox(width: 10),
              Text(
                offer.formattedOriginalPrice,
                style: const TextStyle(
                  color: Colors.grey,
                  decoration: TextDecoration.lineThrough,
                ),
              ),
            ],
          ],
        ),
        const SizedBox(height: 10),
        Text(
          'Expire ${_remainingTimeLabel()}',
          style: TextStyle(
            color: Colors.orange.shade800,
            fontWeight: FontWeight.w600,
          ),
        ),
      ],
    );
  }

  Widget _buildMerchantCard() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              offer.merchantName,
              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
            ),
            const SizedBox(height: 6),
            Text('${offer.areaLabel} · ${_distanceLabel()}'),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: () {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text('Itinéraire bientôt disponible.'),
                  ),
                );
              },
              icon: const Icon(Icons.directions_outlined),
              label: const Text('Itinéraire'),
            ),
          ],
        ),
      ),
    );
  }

Widget _buildPickupSlots() {
  return Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      const Text(
        'Créneau de retrait',
        style: TextStyle(fontWeight: FontWeight.bold),
      ),
      const SizedBox(height: 10),
      RadioGroup<PickupSlot>(
        groupValue: _selectedSlot,
        onChanged: (value) => setState(() => _selectedSlot = value),
        child: Column(
          children: offer.pickupSlots
              .map(
                (slot) => RadioListTile<PickupSlot>(
                  contentPadding: EdgeInsets.zero,
                  value: slot,
                  enabled: !slot.isFull,
                  title: Text(_formatSlot(slot)),
                  subtitle: Text('${slot.availablePlaces} places'),
                ),
              )
              .toList(),
        ),
      ),
    ],
  );
}

  Widget _buildQuantitySelector() {
    return Row(
      children: [
        const Text(
          'Quantité',
          style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
        ),
        const Spacer(),
        IconButton(
          onPressed: _quantity > 1
              ? () {
                  setState(() {
                    _quantity--;
                  });
                }
              : null,
          icon: const Icon(Icons.remove_circle_outline),
        ),
        Text(
          '$_quantity',
          style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
        ),
        IconButton(
          onPressed: _quantity < offer.remainingQuantity
              ? () {
                  setState(() {
                    _quantity++;
                  });
                }
              : null,
          icon: const Icon(Icons.add_circle_outline),
        ),
      ],
    );
  }

  Widget _buildAllergens() {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        const Padding(
          padding: EdgeInsets.only(top: 8),
          child: Text(
            'Allergènes :',
            style: TextStyle(fontWeight: FontWeight.bold),
          ),
        ),
        ...offer.allergens.map((allergen) => Chip(label: Text(allergen))),
      ],
    );
  }

  Widget _buildReserveButton() {
    final canReserve = offer.isAvailable && _selectedSlot != null;

    return SizedBox(
      height: 52,
      width: double.infinity,
      child: FilledButton(
        onPressed: canReserve ? _reserveOffer : null,
        child: Text(
          canReserve
              ? 'Réserver · ${offer.formattedPrice}'
              : 'Offre indisponible',
        ),
      ),
    );
  }

  void _reserveOffer() {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          '$_quantity produit(s) réservé(s) pour ${_formatSlot(_selectedSlot!)}.',
        ),
      ),
    );
  }

  String _distanceLabel() {
    if (offer.distanceKm < 1) {
      return '${(offer.distanceKm * 1000).round()} m';
    }

    return '${offer.distanceKm.toStringAsFixed(1)} km';
  }

  String _remainingTimeLabel() {
    final duration = offer.expiresAt.difference(DateTime.now());

    if (duration.isNegative) {
      return 'est expirée';
    }

    if (duration.inHours < 1) {
      return 'dans ${duration.inMinutes} min';
    }

    final minutes = duration.inMinutes.remainder(60);

    return 'dans ${duration.inHours} h ${minutes.toString().padLeft(2, '0')}';
  }

  String _formatSlot(PickupSlot slot) {
    String formatTime(DateTime time) {
      final hour = time.hour.toString().padLeft(2, '0');
      final minute = time.minute.toString().padLeft(2, '0');

      return '$hour:$minute';
    }

    return '${formatTime(slot.start)} – ${formatTime(slot.end)}';
  }
}
