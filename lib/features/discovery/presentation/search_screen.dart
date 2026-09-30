import 'package:flutter/material.dart';

import 'package:repo_partage_plus/features/discovery/presentation/widgets/discovery_widgets.dart';

/// Recherche d'offres autour du point de départ (sans compte).
class SearchScreen extends StatelessWidget {
  const SearchScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Recherche')),
      body: const Column(
        children: [
          OriginBar(),
          Divider(),
          Expanded(child: OffersBrowser(autofocusSearch: true)),
        ],
      ),
    );
  }
}
