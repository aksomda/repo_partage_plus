import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'package:repo_partage_plus/core/location/geo.dart';
import 'package:repo_partage_plus/core/location/location.dart';
import 'package:repo_partage_plus/core/offline/sync_controller.dart';
import 'package:repo_partage_plus/core/router/app_routes.dart';
import 'package:repo_partage_plus/core/theme/app_theme.dart';
import 'package:repo_partage_plus/features/auth/presentation/widgets/auth_widgets.dart';
import 'package:repo_partage_plus/features/discovery/presentation/widgets/discovery_widgets.dart';
import 'package:repo_partage_plus/features/offers/data/offers_repository.dart';
import 'package:repo_partage_plus/features/offers/presentation/widgets/offer_widgets.dart';
import 'package:repo_partage_plus/features/recommendations/data/offer_search_agent.dart';
import 'package:repo_partage_plus/features/recommendations/data/preferences.dart';
import 'package:repo_partage_plus/features/recommendations/data/voice_input.dart';
import 'package:repo_partage_plus/features/recommendations/domain/hybrid_recommender.dart';
import 'package:repo_partage_plus/features/recommendations/domain/local_ranker.dart';
import 'package:repo_partage_plus/features/recommendations/domain/offer_search.dart';
import 'package:repo_partage_plus/core/widgets/app_menu.dart';

/// Rayon des zones de la vue « par zone », en km.
const zoneRadiusKm = 0.5;

/// Recommandations : classement local, affiné par l'IA quand le réseau est là.
class RecommendationsScreen extends ConsumerStatefulWidget {
  const RecommendationsScreen({super.key});

  @override
  ConsumerState<RecommendationsScreen> createState() =>
      _RecommendationsScreenState();
}

class _RecommendationsScreenState extends ConsumerState<RecommendationsScreen> {
  var _byZone = false;

  @override
  void initState() {
    super.initState();
    Future.microtask(
      ref.read(recommendationsControllerProvider.notifier).refine,
    );
  }

  Future<void> _refresh() async {
    await ref.read(syncControllerProvider.notifier).syncNow();
    await ref.read(recommendationsControllerProvider.notifier).refine();
  }

  @override
  Widget build(BuildContext context) {
    final result = ref.watch(recommendationsProvider);
    final origin = ref.watch(originProvider).place;
    final search = ref.watch(offerSearchProvider).result;
    final items = applySearch(result.items, search);

    return Scaffold(
      drawer: const AppMenu(currentLocation: AppRoutes.recommendations),
      appBar: AppBar(
        leading: backOrMenuButton(context),
        title: const Text('Recommandations'),
        actions: [
          IconButton(
            tooltip: _byZone ? 'Afficher en liste' : 'Regrouper par zone',
            icon: Icon(_byZone ? Icons.view_list : Icons.workspaces_outline),
            onPressed: () => setState(() => _byZone = !_byZone),
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _refresh,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
          children: [
            const _Assistant(),
            const SizedBox(height: 12),
            const _PreferencesPanel(),
            const SizedBox(height: 8),
            _SourceBanner(source: result.source),
            const SizedBox(height: 8),
            if (search != null)
              _SearchBanner(result: search, count: items.length),
            if (items.isEmpty)
              search != null
                  ? EmptyState(
                      icon: Icons.search_off,
                      title: 'Aucune offre ne correspond',
                      message: '« ${search.request} »',
                      action: OutlinedButton(
                        onPressed: ref.read(offerSearchProvider.notifier).clear,
                        child: const Text('Tout afficher'),
                      ),
                    )
                  : const EmptyState(
                      icon: Icons.search_off,
                      title: 'Aucune offre à recommander',
                      message:
                          'Élargissez la distance maximale ou tirez vers le bas '
                          'pour actualiser.',
                    )
            else if (_byZone && origin != null)
              ..._zones(items, origin)
            else
              for (final item in items.take(50)) _RecoCard(item: item),
          ],
        ),
      ),
    );
  }

  List<Widget> _zones(List<RankedOffer> items, Place origin) {
    final clusters = clusterByProximity(
      items.take(100).toList(),
      lat: (item) => (item.offer['latitude'] as num).toDouble(),
      lng: (item) => (item.offer['longitude'] as num).toDouble(),
      radiusKm: zoneRadiusKm,
      originLat: origin.lat,
      originLng: origin.lng,
    );
    return [
      for (final cluster in clusters) ...[
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 12, 4, 6),
          child: Row(
            children: [
              const Icon(
                Icons.workspaces_outline,
                size: 18,
                color: AppColors.primary,
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  'Zone à ${formatDistance(cluster.distanceFrom(origin.lat, origin.lng))}'
                  ' · ${cluster.size} offre${cluster.size > 1 ? 's' : ''}',
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
              ),
              Text(
                formatWalkingTime(cluster.distanceFrom(origin.lat, origin.lng)),
                style: const TextStyle(
                  color: AppColors.textMuted,
                  fontSize: 12,
                ),
              ),
            ],
          ),
        ),
        for (final item in cluster.items) _RecoCard(item: item),
      ],
    ];
  }
}

class _Assistant extends StatelessWidget {
  const _Assistant();

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Container(
          width: 64,
          height: 64,
          decoration: const BoxDecoration(
            color: AppColors.primarySoft,
            shape: BoxShape.circle,
          ),
          child: const Icon(
            Icons.smart_toy_outlined,
            size: 34,
            color: AppColors.primary,
          ),
        ),
        const SizedBox(height: 8),
        const Text(
          'Bonjour !',
          style: TextStyle(fontWeight: FontWeight.w700, fontSize: 16),
        ),
        const Text(
          'Voici des offres qui pourraient vous intéresser selon vos '
          'préférences et votre position.',
          textAlign: TextAlign.center,
          style: TextStyle(color: AppColors.textMuted),
        ),
      ],
    );
  }
}

/// Souhaits en texte libre ou dictés, et critères du score local.
class _PreferencesPanel extends ConsumerStatefulWidget {
  const _PreferencesPanel();

  @override
  ConsumerState<_PreferencesPanel> createState() => _PreferencesPanelState();
}

class _PreferencesPanelState extends ConsumerState<_PreferencesPanel> {
  final _text = TextEditingController();
  var _listening = false;
  var _filled = false;

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  RecoPreferences get _prefs => ref.read(recoPreferencesProvider);

  Future<void> _save(RecoPreferences preferences) =>
      ref.read(recoPreferencesProvider.notifier).update(preferences);

  List<RankedOffer> get _items => ref.read(recommendationsProvider).items;

  OfferSearchController get _search => ref.read(offerSearchProvider.notifier);

  /// Demande écrite ou dictée : préférences enregistrées, classement
  /// affiné, puis liste filtrée par l'agent IA.
  Future<void> _submitText() async {
    FocusScope.of(context).unfocus();
    final text = _text.text.trim();
    await _save(_prefs.copyWith(text: text));
    final outcome = await _search.searchText(text, _items);
    if (mounted) _show(outcome);
    await ref.read(recommendationsControllerProvider.notifier).refine();
  }

  /// Micro : enregistre la voix (l'agent retranscrit et filtre) ; sinon,
  /// dictée de l'appareil.
  Future<void> _toggleVoice() async {
    final phase = ref.read(offerSearchProvider).phase;
    if (phase == OfferSearchPhase.recording) return _sendRecording();
    if (_listening) return _dictate();
    final outcome = await _search.startRecording(onLimit: _sendRecording);
    if (outcome is SearchNeedsDictation && mounted) {
      if (outcome.reason != null) {
        showMessage(context, '${outcome.reason} : dictée de l’appareil');
      }
      await _dictate();
    }
  }

  Future<void> _sendRecording() async {
    final outcome = await _search.stopAndSearch(_items);
    if (!mounted) return;
    if (outcome case SearchDone(:final result)) {
      _text.text = result.request;
      await _save(_prefs.copyWith(text: result.request));
      await ref.read(recommendationsControllerProvider.notifier).refine();
    } else if (outcome case SearchNeedsDictation(:final reason)) {
      showMessage(
        context,
        '${reason ?? 'IA indisponible'} : dictée de l’appareil',
      );
      await _dictate();
    } else {
      _show(outcome);
    }
  }

  void _show(OfferSearchOutcome? outcome) {
    if (outcome case SearchFailed(:final message)) {
      showMessage(context, message, error: true);
    }
  }

  /// Dictée de l'appareil (reconnaissance vocale du système).
  Future<void> _dictate() async {
    final voice = ref.read(voiceInputProvider);
    if (_listening) {
      await voice.stop();
      setState(() => _listening = false);
      return;
    }
    final started = await voice.start(
      onResult: (text, done) {
        if (!mounted) return;
        _text.text = text;
        if (done) {
          setState(() => _listening = false);
          _submitText();
        }
      },
    );
    if (!mounted) return;
    if (started) {
      setState(() => _listening = true);
    } else {
      showMessage(
        context,
        'Dictée indisponible : autorisez le micro ou saisissez votre demande',
        error: true,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final prefs = ref.watch(recoPreferencesProvider);
    final categories = ref.watch(categoriesProvider);
    final refining = ref.watch(recommendationsControllerProvider).refining;
    final search = ref.watch(offerSearchProvider);
    final recording = search.phase == OfferSearchPhase.recording;
    final thinking = search.phase == OfferSearchPhase.thinking;
    if (!_filled && prefs.text.isNotEmpty) {
      _text.text = prefs.text;
      _filled = true;
    }

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              controller: _text,
              maxLength: 500,
              minLines: 1,
              maxLines: 3,
              textInputAction: TextInputAction.search,
              onSubmitted: (_) => _submitText(),
              decoration: InputDecoration(
                hintText: 'Ex. : légumes pour ce soir, pas trop cher…',
                counterText: '',
                prefixIcon: const Icon(Icons.auto_awesome_outlined),
                suffixIcon: IconButton(
                  tooltip: recording
                      ? 'Envoyer l’enregistrement'
                      : _listening
                      ? 'Arrêter la dictée'
                      : 'Parler',
                  icon: Icon(
                    recording || _listening
                        ? Icons.stop_circle_outlined
                        : Icons.mic_none,
                    color: recording || _listening ? AppColors.danger : null,
                  ),
                  onPressed: thinking ? null : _toggleVoice,
                ),
              ),
            ),
            if (recording)
              _RecordingBar(
                startedAt: search.startedAt ?? DateTime.now(),
                onCancel: _search.cancelRecording,
              )
            else if (thinking)
              const Padding(
                padding: EdgeInsets.only(top: 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    LinearProgressIndicator(),
                    SizedBox(height: 4),
                    Text(
                      'L’IA analyse votre demande…',
                      style: TextStyle(color: AppColors.primary, fontSize: 12),
                    ),
                  ],
                ),
              )
            else if (_listening)
              const Padding(
                padding: EdgeInsets.only(top: 6),
                child: Text(
                  'Je vous écoute…',
                  style: TextStyle(color: AppColors.danger, fontSize: 12),
                ),
              ),
            const SizedBox(height: 8),
            FilledButton.icon(
              onPressed: refining || thinking || recording ? null : _submitText,
              icon: refining || thinking
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.white,
                      ),
                    )
                  : const Icon(Icons.auto_awesome),
              label: const Text('Recommander'),
            ),
            ExpansionTile(
              tilePadding: EdgeInsets.zero,
              title: const Text(
                'Critères',
                style: TextStyle(fontWeight: FontWeight.w600),
              ),
              children: [
                _label('Catégories recherchées'),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    for (final category in categories)
                      FilterChip(
                        label: Text(category['name'] as String),
                        selected: prefs.categoryIds.contains(category['id']),
                        onSelected: (selected) => _save(
                          prefs.copyWith(
                            categoryIds: selected
                                ? {...prefs.categoryIds, category['id'] as int}
                                : ({...prefs.categoryIds}
                                    ..remove(category['id'])),
                          ),
                        ),
                      ),
                  ],
                ),
                _label('Type de publieur'),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    for (final entry in publisherLabels.entries)
                      FilterChip(
                        label: Text(entry.value),
                        selected: prefs.publisherTypes.contains(entry.key),
                        onSelected: (selected) => _save(
                          prefs.copyWith(
                            publisherTypes: selected
                                ? {...prefs.publisherTypes, entry.key}
                                : ({...prefs.publisherTypes}
                                    ..remove(entry.key)),
                          ),
                        ),
                      ),
                  ],
                ),
                _label('Prix maximum par unité'),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    for (final price in const [null, 0, 500, 1000, 2000, 5000])
                      ChoiceChip(
                        label: Text(
                          price == null ? 'Pas de limite' : formatPrice(price),
                        ),
                        selected: prefs.maxPrice == price,
                        labelStyle: TextStyle(
                          color: prefs.maxPrice == price
                              ? Colors.white
                              : AppColors.text,
                        ),
                        onSelected: (_) =>
                            _save(prefs.copyWith(maxPrice: () => price)),
                      ),
                  ],
                ),
                _label('Distance maximale'),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    for (final km in searchRadii.where((km) => km.isFinite))
                      ChoiceChip(
                        label: Text('${km.round()} km'),
                        selected: prefs.maxDistanceKm == km,
                        labelStyle: TextStyle(
                          color: prefs.maxDistanceKm == km
                              ? Colors.white
                              : AppColors.text,
                        ),
                        onSelected: (_) =>
                            _save(prefs.copyWith(maxDistanceKm: km)),
                      ),
                  ],
                ),
                const SizedBox(height: 8),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _label(String text) => Padding(
    padding: const EdgeInsets.only(top: 8, bottom: 6),
    child: Align(
      alignment: Alignment.centerLeft,
      child: Text(text, style: const TextStyle(color: AppColors.textMuted)),
    ),
  );
}

/// Enregistrement en cours : durée, rappel du geste pour envoyer, annuler.
class _RecordingBar extends StatelessWidget {
  const _RecordingBar({required this.startedAt, required this.onCancel});

  final DateTime startedAt;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Row(
        children: [
          const Icon(
            Icons.fiber_manual_record,
            color: AppColors.danger,
            size: 14,
          ),
          const SizedBox(width: 6),
          Expanded(
            child: StreamBuilder<int>(
              stream: Stream.periodic(const Duration(seconds: 1), (i) => i),
              builder: (context, _) {
                final elapsed = DateTime.now().difference(startedAt).inSeconds;
                final left =
                    OfferSearchController.maxRecording.inSeconds - elapsed;
                return Text(
                  'Enregistrement ${elapsed ~/ 60}:'
                  '${(elapsed % 60).toString().padLeft(2, '0')} · touchez ■ '
                  'pour envoyer${left <= 10 ? ' ($left s)' : ''}',
                  style: const TextStyle(color: AppColors.danger, fontSize: 12),
                );
              },
            ),
          ),
          TextButton(onPressed: onCancel, child: const Text('Annuler')),
        ],
      ),
    );
  }
}

/// Filtre de l'agent IA appliqué à la liste, retirable.
class _SearchBanner extends ConsumerWidget {
  const _SearchBanner({required this.result, required this.count});

  final OfferSearchResult result;
  final int count;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Container(
        padding: const EdgeInsets.fromLTRB(12, 10, 4, 10),
        decoration: BoxDecoration(
          color: AppColors.primarySoft,
          borderRadius: BorderRadius.circular(AppTheme.radius),
        ),
        child: Row(
          children: [
            const Icon(Icons.auto_awesome, color: AppColors.primary, size: 20),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '« ${result.request} »',
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                  Text(
                    result.summary ??
                        '${count <= 1 ? '$count offre retenue' : '$count offres retenues'}'
                            ' par ${result.engine}',
                    style: const TextStyle(fontSize: 12),
                  ),
                  if (result.summary != null)
                    Text(
                      '${count <= 1 ? '$count offre' : '$count offres'} · filtré par ${result.engine}',
                      style: const TextStyle(
                        fontSize: 11,
                        color: AppColors.textMuted,
                      ),
                    ),
                ],
              ),
            ),
            TextButton(
              onPressed: ref.read(offerSearchProvider.notifier).clear,
              child: const Text('Tout afficher'),
            ),
          ],
        ),
      ),
    );
  }
}

/// Indique si le classement vient de l'IA ou de l'appareil.
class _SourceBanner extends ConsumerWidget {
  const _SourceBanner({required this.source});

  final RecoSource source;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final status = ref.watch(recommendationsControllerProvider);
    final (icon, text, color) = switch (source) {
      RecoSource.ai => (
        Icons.auto_awesome,
        'Classement affiné par l’IA',
        AppColors.primary,
      ),
      RecoSource.local when status.refining => (
        Icons.hourglass_top,
        'Affinage par l’IA en cours… (classement local affiché)',
        AppColors.textMuted,
      ),
      RecoSource.local => (
        Icons.phone_android,
        status.notice ?? 'Classement calculé sur l’appareil',
        AppColors.textMuted,
      ),
    };
    return Row(
      children: [
        Icon(icon, size: 16, color: color),
        const SizedBox(width: 6),
        Expanded(
          child: Text(text, style: TextStyle(color: color, fontSize: 12)),
        ),
      ],
    );
  }
}

class _RecoCard extends StatelessWidget {
  const _RecoCard({required this.item});

  final RankedOffer item;

  @override
  Widget build(BuildContext context) {
    final offer = item.offer;
    final km = item.distanceKm;
    final publisher = publisherLabels[offer['publisher_type']];

    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Card(
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () => context.push(AppRoutes.offer('${item.id}')),
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    OfferThumbnail(offer: offer, size: 56),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            offer['title'] as String,
                            style: const TextStyle(fontWeight: FontWeight.w700),
                          ),
                          Text(
                            '${offer['donor_name'] ?? ''}'
                            '${publisher == null ? '' : ' · $publisher'}',
                            style: const TextStyle(
                              color: AppColors.textMuted,
                              fontSize: 12,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            [
                              if (km != null)
                                '${formatDistance(km)} · ${formatWalkingTime(km)}',
                              formatPrice(offer['price'] as num?),
                              formatExpiry(offer),
                            ].join(' · '),
                            style: const TextStyle(fontSize: 12),
                          ),
                        ],
                      ),
                    ),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 4,
                      ),
                      decoration: const ShapeDecoration(
                        color: AppColors.primarySoft,
                        shape: StadiumBorder(),
                      ),
                      child: Text(
                        '${item.score.total.round()}%',
                        style: const TextStyle(
                          color: AppColors.primary,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ],
                ),
                if (item.reasons.isNotEmpty) ...[
                  const SizedBox(height: 6),
                  Wrap(
                    spacing: 6,
                    runSpacing: 4,
                    children: [
                      for (final reason in item.reasons.take(4))
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 2,
                          ),
                          decoration: const ShapeDecoration(
                            color: AppColors.background,
                            shape: StadiumBorder(),
                          ),
                          child: Text(
                            reason,
                            style: const TextStyle(fontSize: 11),
                          ),
                        ),
                    ],
                  ),
                ],
                if (item.aiReason != null) ...[
                  const SizedBox(height: 6),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Icon(
                        Icons.auto_awesome,
                        size: 14,
                        color: AppColors.accent,
                      ),
                      const SizedBox(width: 4),
                      Expanded(
                        child: Text(
                          item.aiReason!,
                          style: const TextStyle(
                            fontStyle: FontStyle.italic,
                            fontSize: 12,
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
