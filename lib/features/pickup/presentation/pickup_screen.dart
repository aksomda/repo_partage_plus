import 'package:flutter/material.dart';

import 'package:repo_partage_plus/core/widgets/placeholder_screen.dart';

class PickupScreen extends StatelessWidget {
  const PickupScreen({super.key, required this.reservationId});

  final String reservationId;

  @override
  Widget build(BuildContext context) {
    return PlaceholderScreen(
      title: 'Retrait',
      details: 'Réservation n° $reservationId',
    );
  }
}
