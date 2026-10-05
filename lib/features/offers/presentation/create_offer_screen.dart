import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'package:repo_partage_plus/core/countries/country_widgets.dart';
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
import 'package:repo_partage_plus/features/offers/data/offer_draft.dart';
import 'package:repo_partage_plus/features/offers/data/offers_repository.dart';
import 'package:repo_partage_plus/features/offers/presentation/widgets/express_draft_card.dart';
import 'package:repo_partage_plus/features/offers/presentation/widgets/offer_widgets.dart';

/// Publication d'une offre, avec ou sans compte. L'offre est visible tout
/// de suite ; l'administrateur peut la retirer après coup en cas d'abus.
///
/// [offerId] : modification d'une offre (pré-remplie), publiée avec ou
/// sans compte, possible tant qu'elle est publiée et que rien n'est réservé.
class CreateOfferScreen extends ConsumerStatefulWidget {
  const CreateOfferScreen({super.key, this.offerId});

  final int? offerId;

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
  final _paymentInfo = PaymentInfoController();
  final _contactEmail = TextEditingController();
  final _address = TextEditingController();

  int? _categoryId;
  late DateTime _expiry;
  late DateTime _pickupStart;
  late DateTime _pickupEnd;

  /// Créneaux supplémentaires (le bénéficiaire choisit le sien).
  final _extraSlots = <({DateTime start, DateTime end})>[];

  /// Nombre maximal de créneaux par offre (comme le serveur).
  static const _maxSlots = 6;
  Place? _place;
  Uint8List? _photo;
  String? _photoMime;

  /// Modification : offre d'origine (null en création).
  Json? _original;

  /// Modification : photo déjà publiée (URL), et photo retirée.
  String? _currentPhotoUrl;
  var _photoRemoved = false;

  bool get _editing => widget.offerId != null;

  /// Modification d'une offre publiée sans compte (jeton de l'appareil).
  bool get _editingGuestOffer => _original?['guest_token'] != null;
  var _free = true;
  var _loading = false;

  /// Adresse remplie automatiquement : remplacée si le lieu change, tant que
  /// l'utilisateur ne l'a pas modifiée.
  String? _autoAddress;
  var _resolvingAddress = false;

  @override
  void initState() {
    super.initState();
    final now = DateTime.now();
    _expiry = DateTime(now.year, now.month, now.day + 1);
    _pickupStart = DateTime(now.year, now.month, now.day, now.hour + 1);
    _pickupEnd = _pickupStart.add(const Duration(hours: 4));
    if (_editing) {
      // Offre du compte, sinon publiée sans compte sur cet appareil.
      _original = [
        ...ref.read(myOffersProvider),
        ...?ref.read(guestOffersProvider).value,
      ].where((offer) => offer['id'] == widget.offerId).firstOrNull;
      if (_original != null) _prefill(_original!);
      return;
    }
    _place = ref.read(originProvider).place;
    if (_place != null && !_place!.isCurrent) _setAutoAddress(_place!.label);
    unawaited(_locate());
  }

  /// Modification : champs remplis avec l'offre enregistrée.
  void _prefill(Json offer) {
    _categoryId = offer['category_id'] as int?;
    _title.text = '${offer['title'] ?? ''}';
    _description.text = '${offer['description'] ?? ''}';
    _quantity.text = '${offer['initial_quantity'] ?? offer['quantity'] ?? 1}';
    _unit.text = '${offer['unit'] ?? 'portion'}';
    if (offer['weight_kg'] case final num weight) _weight.text = '$weight';
    final price = offer['price'] as num? ?? 0;
    _free = price == 0;
    _price.text = price.round().toString();
    if (offer['payment_info'] case final String info when info.isNotEmpty) {
      _paymentInfo.paymentInfo = info;
    }
    _contactEmail.text = '${offer['contact_email'] ?? ''}';
    if (DateTime.tryParse('${offer['expiry_date']}') case final expiry?) {
      _expiry = expiry;
    }
    final slots = offerSlots(offer);
    if (slots.isNotEmpty) {
      _pickupStart = slots.first.start;
      _pickupEnd = slots.first.end;
      _extraSlots.addAll([
        for (final slot in slots.skip(1)) (start: slot.start, end: slot.end),
      ]);
    }
    final lat = (offer['latitude'] as num?)?.toDouble();
    final lng = (offer['longitude'] as num?)?.toDouble();
    final address = '${offer['address'] ?? ''}';
    _address.text = address;
    if (lat != null && lng != null) {
      _place = Place(lat: lat, lng: lng, label: address);
    }
    _currentPhotoUrl = offerPhotoUrl(offer);
  }

  /// Publication express : champs remplis avec le brouillon de l'IA ; un
  /// champ absent du brouillon garde sa valeur.
  void _applyDraft(Json draft) {
    final categories = ref.read(categoriesProvider);
    setState(() {
      if (draft['category_id'] case final int id
          when categories.any((category) => category['id'] == id)) {
        _categoryId = id;
      }
      if (draft['title'] case final String title) _title.text = title;
      if (draft['description'] case final String text) _description.text = text;
      if (draft['quantity'] case final int quantity) {
        _quantity.text = '$quantity';
      }
      if (draft['unit'] case final String unit) _unit.text = unit;
      if (draft['weight_kg'] case final num weight) _weight.text = '$weight';
      final price = draft['price'] as num? ?? 0;
      _free = price == 0;
      if (price > 0) _price.text = price.round().toString();
      final dates = draftDates(draft, DateTime.now());
      if (dates.expiry case final expiry?) _expiry = expiry;
      if (dates.pickupStart case final start?) _pickupStart = start;
      if (dates.pickupEnd case final end?) {
        _pickupEnd = end;
        _extraSlots.clear();
        // La DLC ne peut précéder la fin du retrait.
        final endDay = DateTime(end.year, end.month, end.day);
        if (_expiry.isBefore(endDay)) _expiry = endDay;
      }
    });
  }

  /// Position GPS exacte au moment de publier (la position mémorisée peut
  /// dater), puis adresse lisible : rue, quartier, ville.
  Future<void> _locate() async {
    if (_place != null && !_place!.isCurrent) return;
    try {
      final place = await ref.read(locationGatewayProvider).currentPosition();
      if (!mounted) return;
      // Un point choisi entre-temps sur la carte reste prioritaire.
      if (_place != null && !_place!.isCurrent) return;
      setState(() => _place = place);
    } catch (_) {
      // Refus ou GPS indisponible : position mémorisée ou choix sur la carte.
    }
    final place = _place;
    if (mounted && place != null && place.isCurrent) await _fillAddress(place);
  }

  bool get _addressEditedByUser =>
      _address.text.trim().isNotEmpty && _address.text != _autoAddress;

  void _setAutoAddress(String text) {
    _address.text = text;
    _autoAddress = text;
  }

  /// Nom du lieu (OpenStreetMap) ; jamais à la place d'une saisie manuelle.
  /// Hors ligne, le champ reste vide et la saisie manuelle suffit.
  Future<void> _fillAddress(Place place) async {
    if (_addressEditedByUser) return;
    setState(() => _resolvingAddress = true);
    final name = await ref.read(geocoderProvider).nameOf(place.lat, place.lng);
    if (!mounted) return;
    setState(() => _resolvingAddress = false);
    if (name == null || _place != place || _addressEditedByUser) return;
    _setAutoAddress(name);
  }

  @override
  void dispose() {
    _guest.dispose();
    _paymentInfo.dispose();
    for (final controller in [
      _title,
      _description,
      _quantity,
      _unit,
      _weight,
      _price,
      _contactEmail,
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
    if (_addressEditedByUser) return;
    if (place.isCurrent) {
      _setAutoAddress('');
      await _fillAddress(place);
    } else {
      _setAutoAddress(place.label);
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
      showMessage(context, 'Photo trop lourde (3 Mo maximum)', error: true);
      return;
    }
    setState(() {
      _photo = bytes;
      _photoMime = mime;
    });
  }

  static const _maxPhotoBytes = 3 * 1024 * 1024;

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
    final today = DateTime(now.year, now.month, now.day);
    final date = await showDatePicker(
      context: context,
      // Modification d'une offre : une date passée part d'aujourd'hui.
      initialDate: initial.isBefore(today) ? today : initial,
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

    final slots = [(start: _pickupStart, end: _pickupEnd), ..._extraSlots]
      ..sort((a, b) => a.start.compareTo(b.start));
    if (pickupDatesError(slots.map((slot) => slot.end), _expiry)
        case final problem?) {
      showMessage(context, problem, error: true);
      return;
    }
    final firstStart = slots.first.start;
    final lastEnd = slots
        .map((slot) => slot.end)
        .reduce((a, b) => a.isAfter(b) ? a : b);

    final price = _free ? 0 : num.parse(_price.text.trim());
    final weight = num.tryParse(_weight.text.trim().replaceAll(',', '.'));
    final email = _contactEmail.text.trim().toLowerCase();
    // Pays du publieur, d'après sa position (s'il est déjà connu).
    final country = ref.read(detectedCountryProvider).value;
    final offer = <String, Object?>{
      'category_id': _categoryId,
      'title': _title.text.trim(),
      if (_description.text.trim().isNotEmpty)
        'description': _description.text.trim(),
      'quantity': int.parse(_quantity.text.trim()),
      'unit': _unit.text.trim(),
      'weight_kg': ?weight,
      'price': price,
      if (price > 0) 'payment_info': _paymentInfo.paymentInfo,
      if (email.isNotEmpty) 'contact_email': email,
      if (country != null) ...{
        'country_code': country.code,
        'country_name': country.name,
      },
      'expiry_date': _isoDay,
      'pickup_start': firstStart.toUtc().toIso8601String(),
      'pickup_end': lastEnd.toUtc().toIso8601String(),
      if (_extraSlots.isNotEmpty)
        'slots': [
          for (final slot in slots)
            {
              'start': slot.start.toUtc().toIso8601String(),
              'end': slot.end.toUtc().toIso8601String(),
            },
        ],
      'address': _address.text.trim(),
      'latitude': _place!.lat,
      'longitude': _place!.lng,
      if (_photo != null)
        'photo': 'data:$_photoMime;base64,${base64Encode(_photo!)}'
      // Modification : photo publiée retirée (absente : inchangée).
      else if (_editing && _photoRemoved)
        'photo': null,
    };

    setState(() => _loading = true);
    try {
      if (_editingGuestOffer) {
        await ref.read(guestRepositoryProvider).updateOffer(_original!, offer);
        if (!mounted) return;
        showMessage(context, 'Offre modifiée');
        context.go(AppRoutes.myOffers);
      } else if (_editing) {
        final result = await ref
            .read(offersRepositoryProvider)
            .update(widget.offerId!, offer);
        if (!mounted) return;
        switch (result) {
          case Sent():
            showMessage(context, 'Offre modifiée');
            context.go(AppRoutes.myOffers);
          case Queued():
            showMessage(
              context,
              'Hors ligne : la modification sera envoyée au retour du réseau',
            );
            context.go(AppRoutes.myOffers);
          case Rejected(:final message):
            showMessage(context, message, error: true);
        }
      } else if (ref.read(authTokenProvider) != null) {
        final result = await ref.read(offersRepositoryProvider).create(offer);
        if (!mounted) return;
        switch (result) {
          case Sent():
            showMessage(context, 'Offre publiée');
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
        showMessage(context, 'Offre publiée');
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
    // Lance la détection du pays du publieur, envoyé avec l'offre.
    ref.watch(detectedCountryProvider);

    // Position encore en cours de calcul à l'ouverture : utilisée dès
    // qu'elle est connue, si aucun lieu n'a été choisi entre-temps.
    ref.listen(originProvider, (_, next) {
      if (_place == null && next.place != null) {
        setState(() => _place = next.place);
        unawaited(_fillAddress(next.place!));
      }
    });

    // Offre introuvable (copie locale pas encore synchronisée, ou retirée).
    if (_editing && _original == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Modifier l’offre')),
        body: const Center(
          child: EmptyState(
            icon: Icons.search_off,
            title: 'Offre introuvable',
            message:
                'Elle n’est pas sur cet appareil : revenez à « Mes offres » '
                'et actualisez.',
          ),
        ),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: Text(_editing ? 'Modifier l’offre' : 'Publier une offre'),
      ),
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
                    if (!_editing && ref.watch(canUseExpressDraftProvider))
                      ExpressDraftCard(onDraft: _applyDraft),
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
                        LabeledField(
                          label: 'Description (facultatif)',
                          child: TextFormField(
                            controller: _description,
                            minLines: 1,
                            maxLines: 3,
                            maxLength: 2000,
                            decoration: const InputDecoration(
                              hintText: 'Contenu, état, conditions…',
                              // Limite appliquée sans compteur, pour gagner
                              // une ligne.
                              counterText: '',
                            ),
                          ),
                        ),
                        LabeledField(
                          label: 'Photo (facultatif, 3 Mo max)',
                          child: _photoField(),
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
                          label: 'Poids total (kg) (facultatif)',
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
                              final text = (value ?? '').trim();
                              if (text.isEmpty) return null;
                              final weight = num.tryParse(
                                text.replaceAll(',', '.'),
                              );
                              return weight == null || weight <= 0
                                  ? 'Poids invalide'
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
                          FieldSpan(
                            span: 3,
                            child: LabeledField(
                              label: 'Comment payer ?',
                              required: true,
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  PaymentInfoField(controller: _paymentInfo),
                                  const SizedBox(height: 4),
                                  const Text(
                                    'Le paiement se fait hors application ; '
                                    'l’acheteur saisit la référence de sa '
                                    'transaction.',
                                    style: TextStyle(
                                      color: AppColors.textMuted,
                                      fontSize: 12,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ],
                        if (!loggedIn)
                          FieldSpan.full(
                            child: GuestFields(
                              controller: _guest,
                              returnTo: AppRoutes.createOffer,
                              extraField: _emailField(),
                              notice:
                                  'Publiez sans compte : votre nom et votre '
                                  'téléphone seront visibles des personnes '
                                  'intéressées. Vous pourrez retirer l’offre '
                                  'depuis cet appareil.',
                            ),
                          ),
                        if (loggedIn) _emailField(),
                        FieldSpan(
                          // Seul sur sa rangée sans compte (l'e-mail suit le
                          // téléphone), à côté de l'e-mail sinon.
                          span: loggedIn ? 3 : 4,
                          child: LabeledField(
                            label: 'Lieu de retrait',
                            required: true,
                            child: _pickupPlace(),
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
                            label: _editing
                                ? 'Enregistrer les modifications'
                                : 'Publier l’offre',
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
    // Modification : photo déjà publiée, gardée tant qu'elle n'est ni
    // remplacée ni retirée.
    final currentUrl = photo == null && !_photoRemoved
        ? _currentPhotoUrl
        : null;
    return Row(
      children: [
        if (currentUrl != null) ...[
          ClipRRect(
            borderRadius: BorderRadius.circular(AppTheme.radius),
            child: Image.network(
              currentUrl,
              width: 52,
              height: 52,
              fit: BoxFit.cover,
              errorBuilder: (_, _, _) => const SizedBox.square(
                dimension: 52,
                child: Icon(Icons.image_outlined),
              ),
            ),
          ),
          const SizedBox(width: 12),
        ],
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
              photo == null && currentUrl == null
                  ? 'Ajouter une photo'
                  : 'Changer la photo',
            ),
          ),
        ),
        if (photo != null || currentUrl != null)
          IconButton(
            tooltip: 'Retirer la photo',
            icon: const Icon(Icons.delete_outline, color: AppColors.danger),
            onPressed: () => setState(() {
              _photo = null;
              _photoMime = null;
              _photoRemoved = true;
            }),
          ),
      ],
    );
  }

  /// Ajoute un créneau : début, puis fin (2 h plus tard par défaut).
  Future<void> _addSlot() async {
    final last = [
      _pickupEnd,
      for (final slot in _extraSlots) slot.end,
    ].reduce((a, b) => a.isAfter(b) ? a : b);
    final start = await _pickDateTime(
      last.add(const Duration(hours: 1)),
      'Début du créneau',
    );
    if (start == null || !mounted) return;
    final end = await _pickDateTime(
      start.add(const Duration(hours: 2)),
      'Fin du créneau',
    );
    if (end == null || !mounted) return;
    if (!end.isAfter(start)) {
      showMessage(context, 'La fin doit être après le début', error: true);
      return;
    }
    setState(() => _extraSlots.add((start: start, end: end)));
  }

  /// Créneau principal (début et fin), bouton d'ajout, autres créneaux.
  Widget _pickupSlot() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _mainSlot(),
        if (_extraSlots.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final (index, slot) in _extraSlots.indexed)
                  InputChip(
                    label: Text(formatPeriod(slot.start, slot.end)),
                    onDeleted: () =>
                        setState(() => _extraSlots.removeAt(index)),
                    deleteButtonTooltipMessage: 'Retirer ce créneau',
                  ),
              ],
            ),
          ),
      ],
    );
  }

  Widget _mainSlot() {
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
        IconButton(
          tooltip: 'Ajouter un créneau',
          icon: const Icon(Icons.add_circle_outline),
          onPressed: 1 + _extraSlots.length >= _maxSlots ? null : _addSlot,
        ),
      ],
    );
  }

  /// Jamais affichée aux autres usagers : sert à prévenir le publieur.
  Widget _emailField() => LabeledField(
    label: 'Adresse e-mail (facultatif)',
    child: TextFormField(
      controller: _contactEmail,
      keyboardType: TextInputType.emailAddress,
      autofillHints: const [AutofillHints.email],
      decoration: const InputDecoration(
        hintText: 'exemple@mail.com',
        // Jamais affichée aux autres usagers.
        suffixIcon: Tooltip(
          message:
              'Non affichée : sert à vous prévenir si '
              'l’offre est retirée',
          child: Icon(Icons.info_outline, size: 18),
        ),
      ),
      validator: (value) =>
          (value?.trim().isEmpty ?? true) ? null : validateEmail(value),
    ),
  );

  /// Point sur la carte, coordonnées et adresse lisible sur une même ligne
  /// (empilés sur écran étroit).
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
      decoration: InputDecoration(
        hintText: _resolvingAddress
            ? 'Recherche de l’adresse…'
            : 'Adresse, repère (ex. : face au marché)',
        suffixIcon: _resolvingAddress
            ? const Padding(
                padding: EdgeInsets.all(14),
                child: SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              )
            : null,
      ),
      validator: (value) =>
          (value?.trim().length ?? 0) < 3 ? 'Adresse obligatoire' : null,
    );

    // Sur écran large, latitude et longitude s'empilent pour laisser la
    // place au bouton et au champ adresse.
    Widget? coordinates({required bool stacked}) => _place == null
        ? null
        : Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(
                Icons.my_location,
                size: 16,
                color: AppColors.textMuted,
              ),
              const SizedBox(width: 6),
              SelectableText(
                'Latitude : ${_place!.lat.toStringAsFixed(6)}'
                '${stacked ? '\n' : '   '}'
                'Longitude : ${_place!.lng.toStringAsFixed(6)}',
                style: const TextStyle(
                  color: AppColors.textMuted,
                  fontSize: 13,
                ),
              ),
            ],
          );

    return LayoutBuilder(
      builder: (context, constraints) => constraints.maxWidth < 640
          ? Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                mapButton,
                if (_place != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: coordinates(stacked: false),
                    ),
                  ),
                const SizedBox(height: 8),
                address,
              ],
            )
          : Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(child: mapButton),
                if (_place != null) ...[
                  const SizedBox(width: 12),
                  // Centré verticalement sur la hauteur du bouton (52).
                  SizedBox(
                    height: 52,
                    child: Center(child: coordinates(stacked: true)),
                  ),
                ],
                const SizedBox(width: 12),
                Expanded(child: address),
              ],
            ),
    );
  }
}
