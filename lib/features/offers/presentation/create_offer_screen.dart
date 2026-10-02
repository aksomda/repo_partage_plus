import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'package:repo_partage_plus/core/guest/guest_fields.dart';
import 'package:repo_partage_plus/core/guest/guest_repository.dart';
import 'package:repo_partage_plus/core/location/location.dart';
import 'package:repo_partage_plus/core/network/api_client.dart';
import 'package:repo_partage_plus/core/offline/offline_data.dart';
import 'package:repo_partage_plus/core/offline/sync_controller.dart';
import 'package:repo_partage_plus/core/router/app_routes.dart';
import 'package:repo_partage_plus/core/storage/local_store.dart';
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
  Uint8List? _photo;
  String? _photoMime;
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

  /// Photo réduite (1280 px, JPEG ~75 %) pour un envoi léger, même hors ligne.
  Future<void> _pickPhoto() async {
    var source = ImageSource.gallery;
    final mobile =
        !kIsWeb &&
        (defaultTargetPlatform == TargetPlatform.android ||
            defaultTargetPlatform == TargetPlatform.iOS);
    if (mobile) {
      final chosen = await showModalBottomSheet<ImageSource>(
        context: context,
        builder: (context) => SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: const Icon(Icons.photo_camera_outlined),
                title: const Text('Prendre une photo'),
                onTap: () => Navigator.pop(context, ImageSource.camera),
              ),
              ListTile(
                leading: const Icon(Icons.photo_library_outlined),
                title: const Text('Choisir dans la galerie'),
                onTap: () => Navigator.pop(context, ImageSource.gallery),
              ),
            ],
          ),
        ),
      );
      if (chosen == null) return;
      source = chosen;
    }

    final XFile? file;
    try {
      file = await ImagePicker().pickImage(
        source: source,
        maxWidth: 1280,
        maxHeight: 1280,
        imageQuality: 75,
      );
    } catch (_) {
      if (mounted) {
        showMessage(context, 'Impossible d’ouvrir les photos', error: true);
      }
      return;
    }
    if (file == null) return;
    final bytes = await file.readAsBytes();
    final mime = _imageType(bytes);
    if (!mounted) return;
    if (mime == null) {
      showMessage(
        context,
        'Format non pris en charge : JPEG, PNG ou WebP',
        error: true,
      );
      return;
    }
    if (bytes.length > _maxPhotoBytes) {
      showMessage(context, 'Photo trop lourde (2 Mo maximum)', error: true);
      return;
    }
    setState(() {
      _photo = bytes;
      _photoMime = mime;
    });
  }

  static const _maxPhotoBytes = 2 * 1024 * 1024;

  /// Type d'image d'après ses premiers octets (comme le serveur).
  static String? _imageType(Uint8List bytes) {
    if (bytes.length < 12) return null;
    if (bytes[0] == 0xFF && bytes[1] == 0xD8 && bytes[2] == 0xFF) {
      return 'image/jpeg';
    }
    if (bytes[0] == 0x89 && bytes[1] == 0x50 && bytes[2] == 0x4E) {
      return 'image/png';
    }
    if (ascii.decode(bytes.sublist(0, 4), allowInvalid: true) == 'RIFF' &&
        ascii.decode(bytes.sublist(8, 12), allowInvalid: true) == 'WEBP') {
      return 'image/webp';
    }
    return null;
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
      if (_photo != null)
        'photo': 'data:$_photoMime;base64,${base64Encode(_photo!)}',
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

  /// Recharge les catégories et prévient si le serveur ne répond pas.
  Future<void> _reloadCategories() async {
    await ref.read(syncControllerProvider.notifier).syncNow();
    if (!mounted) return;
    final saved = asJsonList(
      await ref.read(localStoreProvider).readSnapshot('categories'),
    );
    if (saved.isEmpty && mounted) {
      showMessage(
        context,
        'Serveur injoignable : vérifiez la connexion puis réessayez',
        error: true,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final loggedIn = ref.watch(authTokenProvider) != null;
    final categories = ref.watch(categoriesProvider);
    final syncing = ref.watch(syncControllerProvider.select((s) => s.syncing));

    // Position encore en cours de calcul à l'ouverture : utilisée dès
    // qu'elle est connue, si aucun lieu n'a été choisi entre-temps.
    ref.listen(originProvider, (_, next) {
      if (_place == null && next.place != null) {
        setState(() => _place = next.place);
      }
    });

    return Scaffold(
      appBar: AppBar(title: const Text('Publier une offre')),
      body: Form(
        key: _form,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 12),
          children: [
            Center(
              child: ConstrainedBox(
                // Grand écran : jusqu'à 4 colonnes de champs, sans défilement.
                constraints: const BoxConstraints(maxWidth: 1200),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    FieldGrid(
                      children: [
                        FieldSpan.full(
                          child: LabeledField(
                            label: 'Catégorie',
                            required: true,
                            child: _categoryPicker(categories, syncing),
                          ),
                        ),
                        FieldSpan(
                          span: 2,
                          child: LabeledField(
                            label: 'Titre',
                            required: true,
                            child: TextFormField(
                              controller: _title,
                              textCapitalization: TextCapitalization.sentences,
                              decoration: const InputDecoration(
                                hintText: 'Ex. : Panier de légumes frais',
                              ),
                              validator: (value) =>
                                  (value?.trim().length ?? 0) < 3
                                  ? '3 caractères minimum'
                                  : null,
                            ),
                          ),
                        ),
                        FieldSpan(
                          span: 2,
                          child: LabeledField(
                            label: 'Description (facultatif)',
                            child: TextFormField(
                              controller: _description,
                              minLines: 1,
                              maxLines: 3,
                              maxLength: 2000,
                              decoration: const InputDecoration(
                                hintText:
                                    'Contenu, état, conditions de retrait…',
                                // Limite appliquée sans compteur, pour gagner
                                // une ligne.
                                counterText: '',
                              ),
                            ),
                          ),
                        ),
                        LabeledField(
                          label: 'Quantité',
                          required: true,
                          child: TextFormField(
                            controller: _quantity,
                            keyboardType: TextInputType.number,
                            inputFormatters: [
                              FilteringTextInputFormatter.digitsOnly,
                            ],
                            validator: (value) =>
                                (int.tryParse(value ?? '') ?? 0) < 1
                                ? 'Au moins 1'
                                : null,
                          ),
                        ),
                        LabeledField(
                          label: 'Unité',
                          required: true,
                          child: TextFormField(
                            controller: _unit,
                            decoration: const InputDecoration(
                              hintText: 'portion',
                            ),
                            validator: requiredField('Unité obligatoire'),
                          ),
                        ),
                        LabeledField(
                          label: 'Poids total (kg)',
                          required: true,
                          child: TextFormField(
                            controller: _weight,
                            keyboardType: const TextInputType.numberWithOptions(
                              decimal: true,
                            ),
                            decoration: const InputDecoration(
                              hintText: 'Ex. : 3',
                              helperText:
                                  'Sert à calculer l’impact (gaspillage évité)',
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
                        LabeledField(
                          label: 'Date limite de consommation',
                          required: true,
                          child: OutlinedButton.icon(
                            onPressed: _pickExpiry,
                            icon: const Icon(Icons.event_outlined),
                            label: Text(formatDay(_expiry)),
                          ),
                        ),
                        FieldSpan(
                          span: 2,
                          child: LabeledField(
                            label: 'Prix',
                            required: true,
                            child: SegmentedButton<bool>(
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
                          ),
                        ),
                        FieldSpan(
                          span: 2,
                          child: LabeledField(
                            label: 'Créneau de retrait',
                            required: true,
                            child: _pickupSlot(),
                          ),
                        ),
                        if (!_free) ...[
                          LabeledField(
                            label: 'Prix par unité (F CFA)',
                            required: true,
                            child: TextFormField(
                              controller: _price,
                              keyboardType: TextInputType.number,
                              inputFormatters: [
                                FilteringTextInputFormatter.digitsOnly,
                              ],
                              validator: (value) =>
                                  (int.tryParse(value ?? '') ?? 0) < 1
                                  ? 'Prix obligatoire'
                                  : null,
                            ),
                          ),
                          LabeledField(
                            label: 'Comment payer ?',
                            required: true,
                            child: TextFormField(
                              controller: _paymentInfo,
                              decoration: const InputDecoration(
                                hintText: 'Ex. : Orange Money +226 70 00 00 00',
                                helperText:
                                    'Le paiement se fait hors application ; '
                                    'l’acheteur saisit la référence de sa '
                                    'transaction.',
                                helperMaxLines: 3,
                              ),
                              validator: requiredField(
                                'Moyen de paiement obligatoire',
                              ),
                            ),
                          ),
                        ],
                        FieldSpan(
                          span: 2,
                          child: LabeledField(
                            label: 'Lieu de retrait',
                            required: true,
                            child: _pickupPlace(),
                          ),
                        ),
                        FieldSpan(
                          span: 2,
                          child: LabeledField(
                            label: 'Photo (facultatif)',
                            child: _photoField(),
                          ),
                        ),
                        if (!loggedIn)
                          FieldSpan.full(
                            child: GuestFields(
                              controller: _guest,
                              returnTo: AppRoutes.createOffer,
                              notice:
                                  'Publiez sans compte : votre nom et votre '
                                  'téléphone seront visibles des personnes '
                                  'intéressées. Vous pourrez retirer l’offre '
                                  'depuis cet appareil.',
                            ),
                          ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Center(
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 440),
                        child: SizedBox(
                          width: double.infinity,
                          child: LoadingButton(
                            label: 'Publier l’offre',
                            loading: _loading,
                            onPressed: _submit,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _categoryPicker(List<Json> categories, bool syncing) {
    if (categories.isEmpty) {
      return Row(
        children: [
          Expanded(
            child: Text(
              syncing
                  ? 'Chargement des catégories…'
                  : 'Catégories non chargées : serveur injoignable.',
              style: TextStyle(
                color: syncing ? AppColors.textMuted : AppColors.danger,
              ),
            ),
          ),
          if (syncing)
            const SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          else
            TextButton(
              onPressed: _reloadCategories,
              child: const Text('Réessayer'),
            ),
        ],
      );
    }
    return Wrap(
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
            onSelected: (_) =>
                setState(() => _categoryId = category['id'] as int),
          ),
      ],
    );
  }

  /// Aperçu de la photo choisie, avec changer / retirer.
  Widget _photoField() {
    final photo = _photo;
    return Row(
      children: [
        if (photo != null) ...[
          ClipRRect(
            borderRadius: BorderRadius.circular(AppTheme.radius),
            child: Image.memory(
              photo,
              width: 52,
              height: 52,
              fit: BoxFit.cover,
            ),
          ),
          const SizedBox(width: 12),
        ],
        Expanded(
          child: OutlinedButton.icon(
            onPressed: _pickPhoto,
            style: OutlinedButton.styleFrom(minimumSize: const Size(0, 52)),
            icon: const Icon(Icons.add_a_photo_outlined),
            label: Text(
              photo == null ? 'Ajouter une photo' : 'Changer la photo',
            ),
          ),
        ),
        if (photo != null)
          IconButton(
            tooltip: 'Retirer la photo',
            icon: const Icon(Icons.delete_outline, color: AppColors.danger),
            onPressed: () => setState(() {
              _photo = null;
              _photoMime = null;
            }),
          ),
      ],
    );
  }

  /// Début et fin du créneau de retrait.
  Widget _pickupSlot() {
    return Row(
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
              final value = await _pickDateTime(_pickupEnd, 'Fin du retrait');
              if (value != null) setState(() => _pickupEnd = value);
            },
            child: Text('${formatDay(_pickupEnd)} ${formatHour(_pickupEnd)}'),
          ),
        ),
      ],
    );
  }

  /// Point sur la carte et adresse lisible côte à côte (empilés sur
  /// écran étroit), coordonnées en dessous.
  Widget _pickupPlace() {
    final mapButton = OutlinedButton.icon(
      onPressed: _pickPlace,
      // Même hauteur que le champ adresse voisin.
      style: OutlinedButton.styleFrom(minimumSize: const Size(0, 52)),
      icon: const Icon(Icons.map_outlined),
      label: Text(
        _place == null ? 'Choisir sur la carte' : '${_place!.label} (modifier)',
        overflow: TextOverflow.ellipsis,
      ),
    );
    final address = TextFormField(
      controller: _address,
      decoration: const InputDecoration(
        hintText: 'Adresse, repère (ex. : face au marché)',
      ),
      validator: (value) =>
          (value?.trim().length ?? 0) < 3 ? 'Adresse obligatoire' : null,
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        LayoutBuilder(
          builder: (context, constraints) => constraints.maxWidth < 400
              ? Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [mapButton, const SizedBox(height: 8), address],
                )
              : Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(child: mapButton),
                    const SizedBox(width: 12),
                    Expanded(child: address),
                  ],
                ),
        ),
        if (_place != null)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Row(
              children: [
                const Icon(
                  Icons.my_location,
                  size: 16,
                  color: AppColors.textMuted,
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: SelectableText(
                    'Latitude : ${_place!.lat.toStringAsFixed(6)}   '
                    'Longitude : ${_place!.lng.toStringAsFixed(6)}',
                    style: const TextStyle(
                      color: AppColors.textMuted,
                      fontSize: 13,
                    ),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}
