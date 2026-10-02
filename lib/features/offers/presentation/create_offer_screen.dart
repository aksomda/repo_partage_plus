import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'package:repo_partage_plus/core/guest/guest_fields.dart';
import 'package:repo_partage_plus/core/guest/guest_repository.dart';
import 'package:repo_partage_plus/core/location/location.dart';
import 'package:repo_partage_plus/core/network/api_client.dart';
import 'package:repo_partage_plus/core/offline/sync_controller.dart';
import 'package:repo_partage_plus/core/router/app_routes.dart';
import 'package:repo_partage_plus/core/theme/app_theme.dart';
import 'package:repo_partage_plus/features/auth/presentation/widgets/auth_widgets.dart';
import 'package:repo_partage_plus/features/offers/data/offers_repository.dart';
import 'package:repo_partage_plus/features/offers/presentation/widgets/offer_widgets.dart';

/// Publication d'une offre, avec ou sans compte. L'offre est visible
/// après validation par un modérateur.
class CreateOfferScreen extends ConsumerStatefulWidget {
  const CreateOfferScreen({super.key});

  @override
  ConsumerState<CreateOfferScreen> createState() => _CreateOfferScreenState();
}

class _CreateOfferScreenState extends ConsumerState<CreateOfferScreen> {
  final _form = GlobalKey<FormState>();
  final _guest = GuestFieldsController();
  final _title = TextEditingController();
  final _description = TextEditingController();
  final _quantity = TextEditingController(text: '1');
  final _unit = TextEditingController(text: 'portion');
  final _weight = TextEditingController();
  final _price = TextEditingController(text: '0');
  final _paymentInfo = TextEditingController();
  final _address = TextEditingController();

  int? _categoryId;
  late DateTime _expiry;
  late DateTime _pickupStart;
  late DateTime _pickupEnd;
  Place? _place;
  var _free = true;
  var _loading = false;

  @override
  void initState() {
    super.initState();
    final now = DateTime.now();
    _expiry = DateTime(now.year, now.month, now.day + 1);
    _pickupStart = DateTime(now.year, now.month, now.day, now.hour + 1);
    _pickupEnd = _pickupStart.add(const Duration(hours: 4));
    _place = ref.read(originProvider).place;
    if (_place != null && !_place!.isCurrent) _address.text = _place!.label;
  }

  @override
  void dispose() {
    _guest.dispose();
    for (final controller in [
      _title,
      _description,
      _quantity,
      _unit,
      _weight,
      _price,
      _paymentInfo,
      _address,
    ]) {
      controller.dispose();
    }
    super.dispose();
  }

  Future<void> _pickPlace() async {
    final place = await context.push<Place>(AppRoutes.pickLocation);
    if (place == null) return;
    setState(() => _place = place);
    if (!place.isCurrent || _address.text.isEmpty) {
      _address.text = place.isCurrent ? '' : place.label;
    }
  }

  Future<void> _pickExpiry() async {
    final now = DateTime.now();
    final date = await showDatePicker(
      context: context,
      initialDate: _expiry,
      firstDate: DateTime(now.year, now.month, now.day),
      lastDate: now.add(const Duration(days: 365)),
      helpText: 'Date limite de consommation',
    );
    if (date != null) setState(() => _expiry = date);
  }

  Future<DateTime?> _pickDateTime(DateTime initial, String help) async {
    final now = DateTime.now();
    final date = await showDatePicker(
      context: context,
      initialDate: initial,
      firstDate: DateTime(now.year, now.month, now.day),
      lastDate: now.add(const Duration(days: 60)),
      helpText: help,
    );
    if (date == null || !mounted) return null;
    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(initial),
      helpText: help,
    );
    if (time == null) return null;
    return DateTime(date.year, date.month, date.day, time.hour, time.minute);
  }

  String get _isoDay =>
      '${_expiry.year}-${_expiry.month.toString().padLeft(2, '0')}-'
      '${_expiry.day.toString().padLeft(2, '0')}';

  Future<void> _submit() async {
    if (!_form.currentState!.validate()) return;
    if (_categoryId == null) {
      showMessage(context, 'Choisissez une catégorie', error: true);
      return;
    }
    if (_place == null) {
      showMessage(context, 'Choisissez le lieu de retrait', error: true);
      return;
    }
    if (!_pickupEnd.isAfter(_pickupStart)) {
      showMessage(
        context,
        'La fin du retrait doit être après le début',
        error: true,
      );
      return;
    }

    final price = _free ? 0 : num.parse(_price.text.trim());
    final offer = <String, Object?>{
      'category_id': _categoryId,
      'title': _title.text.trim(),
      if (_description.text.trim().isNotEmpty)
        'description': _description.text.trim(),
      'quantity': int.parse(_quantity.text.trim()),
      'unit': _unit.text.trim(),
      'weight_kg': num.parse(_weight.text.trim().replaceAll(',', '.')),
      'price': price,
      if (price > 0) 'payment_info': _paymentInfo.text.trim(),
      'expiry_date': _isoDay,
      'pickup_start': _pickupStart.toUtc().toIso8601String(),
      'pickup_end': _pickupEnd.toUtc().toIso8601String(),
      'address': _address.text.trim(),
      'latitude': _place!.lat,
      'longitude': _place!.lng,
    };

    setState(() => _loading = true);
    try {
      if (ref.read(authTokenProvider) != null) {
        final result = await ref.read(offersRepositoryProvider).create(offer);
        if (!mounted) return;
        switch (result) {
          case Sent():
            showMessage(context, 'Offre envoyée : visible après validation');
            context.go(AppRoutes.myOffers);
          case Queued():
            showMessage(
              context,
              'Hors ligne : l’offre sera envoyée au retour du réseau',
            );
            context.go(AppRoutes.myOffers);
          case Rejected(:final message):
            showMessage(context, message, error: true);
        }
      } else {
        await ref
            .read(guestRepositoryProvider)
            .publishOffer(offer, _guest.value);
        if (!mounted) return;
        showMessage(context, 'Offre envoyée : visible après validation');
        context.go(AppRoutes.myOffers);
      }
    } catch (error) {
      if (mounted) showMessage(context, error.toString(), error: true);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final loggedIn = ref.watch(authTokenProvider) != null;
    final categories = ref.watch(categoriesProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Publier une offre')),
      body: Form(
        key: _form,
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            LabeledField(
              label: 'Catégorie',
              child: categories.isEmpty
                  ? Row(
                      children: [
                        const Expanded(
                          child: Text(
                            'Catégories non chargées : connexion requise.',
                            style: TextStyle(color: AppColors.danger),
                          ),
                        ),
                        TextButton(
                          onPressed: ref
                              .read(syncControllerProvider.notifier)
                              .syncNow,
                          child: const Text('Réessayer'),
                        ),
                      ],
                    )
                  : Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        for (final category in categories)
                          ChoiceChip(
                            avatar: Icon(
                              categoryIcon(category['icon']),
                              size: 18,
                              color: _categoryId == category['id']
                                  ? Colors.white
                                  : AppColors.primary,
                            ),
                            label: Text(category['name'] as String),
                            labelStyle: TextStyle(
                              color: _categoryId == category['id']
                                  ? Colors.white
                                  : AppColors.text,
                            ),
                            selected: _categoryId == category['id'],
                            onSelected: (_) => setState(
                              () => _categoryId = category['id'] as int,
                            ),
                          ),
                      ],
                    ),
            ),
            LabeledField(
              label: 'Titre',
              child: TextFormField(
                controller: _title,
                textCapitalization: TextCapitalization.sentences,
                decoration: const InputDecoration(
                  hintText: 'Ex. : Panier de légumes frais',
                ),
                validator: (value) => (value?.trim().length ?? 0) < 3
                    ? '3 caractères minimum'
                    : null,
              ),
            ),
            LabeledField(
              label: 'Description (facultatif)',
              child: TextFormField(
                controller: _description,
                maxLines: 3,
                maxLength: 2000,
                decoration: const InputDecoration(
                  hintText: 'Contenu, état, conditions de retrait…',
                ),
              ),
            ),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: LabeledField(
                    label: 'Quantité',
                    child: TextFormField(
                      controller: _quantity,
                      keyboardType: TextInputType.number,
                      inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                      validator: (value) => (int.tryParse(value ?? '') ?? 0) < 1
                          ? 'Au moins 1'
                          : null,
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: LabeledField(
                    label: 'Unité',
                    child: TextFormField(
                      controller: _unit,
                      decoration: const InputDecoration(hintText: 'portion'),
                      validator: requiredField('Unité obligatoire'),
                    ),
                  ),
                ),
              ],
            ),
            LabeledField(
              label: 'Poids total (kg)',
              child: TextFormField(
                controller: _weight,
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                decoration: const InputDecoration(
                  hintText: 'Ex. : 3',
                  helperText: 'Sert à calculer l’impact (gaspillage évité)',
                ),
                validator: (value) {
                  final weight = num.tryParse(
                    (value ?? '').trim().replaceAll(',', '.'),
                  );
                  return weight == null || weight <= 0
                      ? 'Poids obligatoire'
                      : null;
                },
              ),
            ),
            const Text('Prix', style: TextStyle(fontWeight: FontWeight.w600)),
            const SizedBox(height: 6),
            SegmentedButton<bool>(
              segments: const [
                ButtonSegment(
                  value: true,
                  label: Text('Don gratuit'),
                  icon: Icon(Icons.volunteer_activism_outlined),
                ),
                ButtonSegment(
                  value: false,
                  label: Text('Prix réduit'),
                  icon: Icon(Icons.sell_outlined),
                ),
              ],
              selected: {_free},
              onSelectionChanged: (value) =>
                  setState(() => _free = value.first),
            ),
            const SizedBox(height: 12),
            if (!_free) ...[
              LabeledField(
                label: 'Prix par unité (F CFA)',
                child: TextFormField(
                  controller: _price,
                  keyboardType: TextInputType.number,
                  inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                  validator: (value) => (int.tryParse(value ?? '') ?? 0) < 1
                      ? 'Prix obligatoire'
                      : null,
                ),
              ),
              LabeledField(
                label: 'Comment payer ?',
                child: TextFormField(
                  controller: _paymentInfo,
                  decoration: const InputDecoration(
                    hintText: 'Ex. : Orange Money +226 70 00 00 00',
                    helperText:
                        'Le paiement se fait hors application ; l’acheteur '
                        'saisit la référence de sa transaction.',
                    helperMaxLines: 2,
                  ),
                  validator: requiredField('Moyen de paiement obligatoire'),
                ),
              ),
            ],
            LabeledField(
              label: 'Date limite de consommation',
              child: OutlinedButton.icon(
                onPressed: _pickExpiry,
                icon: const Icon(Icons.event_outlined),
                label: Text(formatDay(_expiry)),
              ),
            ),
            LabeledField(
              label: 'Créneau de retrait',
              child: Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: () async {
                        final value = await _pickDateTime(
                          _pickupStart,
                          'Début du retrait',
                        );
                        if (value != null) {
                          setState(() {
                            _pickupStart = value;
                            if (!_pickupEnd.isAfter(value)) {
                              _pickupEnd = value.add(const Duration(hours: 2));
                            }
                          });
                        }
                      },
                      child: Text(
                        '${formatDay(_pickupStart)} ${formatHour(_pickupStart)}',
                      ),
                    ),
                  ),
                  const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 8),
                    child: Text('→'),
                  ),
                  Expanded(
                    child: OutlinedButton(
                      onPressed: () async {
                        final value = await _pickDateTime(
                          _pickupEnd,
                          'Fin du retrait',
                        );
                        if (value != null) setState(() => _pickupEnd = value);
                      },
                      child: Text(
                        '${formatDay(_pickupEnd)} ${formatHour(_pickupEnd)}',
                      ),
                    ),
                  ),
                ],
              ),
            ),
            LabeledField(
              label: 'Lieu de retrait',
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  OutlinedButton.icon(
                    onPressed: _pickPlace,
                    icon: const Icon(Icons.map_outlined),
                    label: Text(
                      _place == null
                          ? 'Choisir sur la carte'
                          : '${_place!.label} (modifier)',
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  const SizedBox(height: 8),
                  TextFormField(
                    controller: _address,
                    decoration: const InputDecoration(
                      hintText: 'Adresse, repère (ex. : face au marché)',
                    ),
                    validator: (value) => (value?.trim().length ?? 0) < 3
                        ? 'Adresse obligatoire'
                        : null,
                  ),
                ],
              ),
            ),
            if (!loggedIn)
              GuestFields(
                controller: _guest,
                returnTo: AppRoutes.createOffer,
                notice:
                    'Publiez sans compte : votre nom et votre téléphone seront '
                    'visibles des personnes intéressées. Vous pourrez retirer '
                    'l’offre depuis cet appareil.',
              ),
            const SizedBox(height: 8),
            LoadingButton(
              label: 'Publier l’offre',
              loading: _loading,
              onPressed: _submit,
            ),
          ],
        ),
      ),
    );
  }
}
