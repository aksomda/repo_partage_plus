import 'package:flutter/material.dart';

import 'package:repo_partage_plus/core/widgets/placeholder_screen.dart';

class OfferDetailScreen extends StatelessWidget {
  const OfferDetailScreen({super.key, required this.offerId});

  final String offerId;

  @override
  Widget build(BuildContext context) {
    return PlaceholderScreen(
      title: "Détail de l'offre",
      details: 'Offre n° $offerId',
    );
  }
}
