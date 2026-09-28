import 'package:flutter/material.dart';

import 'package:repo_partage_plus/core/widgets/placeholder_screen.dart';

class ReservationConfirmationScreen extends StatelessWidget {
  const ReservationConfirmationScreen({super.key, required this.reservationId});

  final String reservationId;

  @override
  Widget build(BuildContext context) {
    return PlaceholderScreen(
      title: 'Confirmation de réservation',
      details: 'Réservation n° $reservationId',
    );
  }
}
