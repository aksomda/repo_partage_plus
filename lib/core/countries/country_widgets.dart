import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:repo_partage_plus/core/countries/countries.dart';
import 'package:repo_partage_plus/core/location/location.dart';
import 'package:repo_partage_plus/core/theme/app_theme.dart';

/// Pays de l'utilisateur d'après sa position (point de départ déjà connu,
/// sinon position actuelle) ; Burkina Faso si elle est inconnue.
final detectedCountryProvider = FutureProvider<Country>((ref) async {
  var place = ref.watch(originProvider.select((state) => state.place));
  if (place == null) {
    try {
      place = await ref.read(locationGatewayProvider).currentPosition();
    } catch (_) {
      return defaultCountry;
    }
  }
  final code = await ref
      .read(geocoderProvider)
      .countryCodeOf(place.lat, place.lng);
  return countryByCode(code) ?? defaultCountry;
});

/// Numéro de téléphone : pays (drapeau, indicatif) + numéro saisi librement.
class PhoneController extends ChangeNotifier {
  PhoneController();

  final number = TextEditingController();
  Country? _country;

  /// true dès que le pays a été choisi ou lu dans un numéro existant :
  /// la géolocalisation ne le remplace plus.
  var _countryFixed = false;

  Country get country => _country ?? defaultCountry;

  set country(Country value) {
    _country = value;
    _countryFixed = true;
    notifyListeners();
  }

  /// Pays détecté par la géolocalisation, s'il n'a pas été choisi.
  void suggest(Country value) {
    if (_countryFixed || _country == value) return;
    _country = value;
    notifyListeners();
  }

  /// Numéro sans espaces ni indicatif.
  String get localNumber => number.text.replaceAll(RegExp(r'[^0-9]'), '');

  /// Numéro complet au format international, ex. `+226 73290554`.
  String get value =>
      localNumber.isEmpty ? '' : '+${country.dialCode} $localNumber';

  /// Pré-remplit avec un numéro enregistré (`+226 73 29 05 54`).
  set value(String text) {
    final found = countryOfNumber(text, preferred: _country);
    if (found != null) {
      _country = found;
      _countryFixed = true;
      final digits = text.replaceAll(RegExp(r'[^0-9]'), '');
      number.text = digits.substring(found.dialCode.length);
    } else {
      number.text = text.replaceAll(RegExp(r'[^0-9]'), '');
    }
    notifyListeners();
  }

  @override
  void dispose() {
    number.dispose();
    super.dispose();
  }
}

/// Champ téléphone avec, devant, le drapeau et l'indicatif du pays détecté
/// (touchez-les pour changer de pays). Le numéro se saisit librement.
class PhoneField extends ConsumerWidget {
  const PhoneField({
    super.key,
    required this.controller,
    this.requiredMessage,
    this.hintText = '73290554',
    this.textInputAction = TextInputAction.next,
  });

  final PhoneController controller;

  /// Message si vide ; null = facultatif.
  final String? requiredMessage;
  final String hintText;
  final TextInputAction textInputAction;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Après la construction : le contrôleur prévient ses auditeurs.
    if (ref.watch(detectedCountryProvider).value case final detected?) {
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => controller.suggest(detected),
      );
    }

    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) => TextFormField(
        controller: controller.number,
        keyboardType: TextInputType.phone,
        textInputAction: textInputAction,
        autofillHints: const [AutofillHints.telephoneNumberNational],
        inputFormatters: [FilteringTextInputFormatter.allow(RegExp('[0-9 ]'))],
        decoration: InputDecoration(
          hintText: hintText,
          prefixIcon: CountryPrefixButton(
            country: controller.country,
            onChanged: (country) => controller.country = country,
          ),
        ),
        validator: (_) {
          final digits = controller.localNumber;
          if (digits.isEmpty) return requiredMessage;
          return digits.length < 6 || digits.length > 15
              ? 'Numéro invalide'
              : null;
        },
      ),
    );
  }
}

/// Drapeau + indicatif, ouvre la liste des pays.
class CountryPrefixButton extends StatelessWidget {
  const CountryPrefixButton({
    super.key,
    required this.country,
    required this.onChanged,
  });

  final Country country;
  final ValueChanged<Country> onChanged;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: '${country.name} : changer de pays',
      child: InkWell(
        borderRadius: BorderRadius.circular(AppTheme.radius),
        onTap: () async {
          final chosen = await showCountryPicker(context);
          if (chosen != null) onChanged(chosen);
        },
        child: Padding(
          padding: const EdgeInsets.only(left: 12, right: 6),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(country.flag, style: const TextStyle(fontSize: 20)),
              const SizedBox(width: 6),
              Text(
                '+${country.dialCode}',
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
              const Icon(Icons.arrow_drop_down, color: AppColors.textMuted),
            ],
          ),
        ),
      ),
    );
  }
}

/// Liste des pays avec recherche (nom, code ou indicatif).
Future<Country?> showCountryPicker(BuildContext context) {
  return showModalBottomSheet<Country>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    backgroundColor: AppColors.surface,
    builder: (context) => const _CountryPicker(),
  );
}

class _CountryPicker extends StatefulWidget {
  const _CountryPicker();

  @override
  State<_CountryPicker> createState() => _CountryPickerState();
}

class _CountryPickerState extends State<_CountryPicker> {
  var _query = '';

  @override
  Widget build(BuildContext context) {
    final query = _query.trim().toLowerCase().replaceAll('+', '');
    final shown = query.isEmpty
        ? countries
        : countries
              .where(
                (country) =>
                    country.name.toLowerCase().contains(query) ||
                    country.code.toLowerCase() == query ||
                    country.dialCode.startsWith(query),
              )
              .toList();

    return SizedBox(
      height: MediaQuery.sizeOf(context).height * 0.75,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: TextField(
              autofocus: true,
              decoration: const InputDecoration(
                hintText: 'Rechercher un pays ou un indicatif',
                prefixIcon: Icon(Icons.search),
                isDense: true,
              ),
              onChanged: (value) => setState(() => _query = value),
            ),
          ),
          Expanded(
            child: ListView.builder(
              itemCount: shown.length,
              itemBuilder: (context, index) {
                final country = shown[index];
                return ListTile(
                  leading: Text(
                    country.flag,
                    style: const TextStyle(fontSize: 24),
                  ),
                  title: Text(country.name),
                  trailing: Text(
                    '+${country.dialCode}',
                    style: const TextStyle(color: AppColors.textMuted),
                  ),
                  onTap: () => Navigator.of(context).pop(country),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

// ---------- Moyen de paiement (offre payante) ----------

/// « Comment payer ? » : opérateur de porte-monnaie électronique du pays,
/// puis numéro. Enregistré sous la forme `ORANGE MONEY : +226 73290554`.
class PaymentInfoController extends PhoneController {
  static const other = 'Autre';

  String? operator;
  final otherOperator = TextEditingController();

  String get operatorName =>
      operator == other ? otherOperator.text.trim() : operator ?? '';

  @override
  set country(Country value) {
    // Les opérateurs dépendent du pays.
    if (value != country) operator = null;
    super.country = value;
  }

  @override
  void suggest(Country value) {
    if (value != country && !_countryFixed) operator = null;
    super.suggest(value);
  }

  void chooseOperator(String? value) {
    operator = value;
    notifyListeners();
  }

  String get paymentInfo {
    final name = operatorName;
    return name.isEmpty ? value : '$name : $value';
  }

  /// Pré-remplit avec un texte enregistré (`ORANGE MONEY : +226 73290554`),
  /// ou d'un format plus ancien sans « : » (`Orange Money 70 00 00 00`).
  set paymentInfo(String text) {
    var separator = text.lastIndexOf(':');
    if (separator < 0) {
      // Opérateur connu en début de texte, sans tenir compte de la casse.
      final lower = text.toLowerCase();
      final known = country.mobileMoneyOperators
          .where((name) => lower.startsWith(name.toLowerCase()))
          .firstOrNull;
      if (known != null) {
        operator = known;
        value = text.substring(known.length);
        notifyListeners();
        return;
      }
    }
    final name = separator < 0 ? '' : text.substring(0, separator).trim();
    value = separator < 0 ? text : text.substring(separator + 1);
    if (name.isEmpty) return;
    final known = country.mobileMoneyOperators
        .where((operator) => operator.toLowerCase() == name.toLowerCase())
        .firstOrNull;
    if (known != null) {
      operator = known;
    } else {
      operator = other;
      otherOperator.text = name;
    }
    notifyListeners();
  }

  @override
  void dispose() {
    otherOperator.dispose();
    super.dispose();
  }
}

class PaymentInfoField extends ConsumerWidget {
  const PaymentInfoField({super.key, required this.controller});

  final PaymentInfoController controller;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final operators = [
          ...controller.country.mobileMoneyOperators,
          PaymentInfoController.other,
        ];
        final fields = [
          DropdownButtonFormField<String>(
            key: ValueKey(controller.country.code),
            isExpanded: true,
            initialValue: controller.operator,
            hint: Text('Opérateur (${controller.country.name})'),
            items: [
              for (final name in operators)
                DropdownMenuItem(value: name, child: Text(name)),
            ],
            onChanged: controller.chooseOperator,
            validator: (value) =>
                value == null ? 'Choisissez un opérateur' : null,
          ),
          if (controller.operator == PaymentInfoController.other)
            TextFormField(
              controller: controller.otherOperator,
              textCapitalization: TextCapitalization.characters,
              decoration: const InputDecoration(hintText: 'Nom de l’opérateur'),
              validator: (value) => (value?.trim().isEmpty ?? true)
                  ? 'Nom de l’opérateur obligatoire'
                  : null,
            ),
          PhoneField(
            controller: controller,
            requiredMessage: 'Numéro obligatoire',
          ),
        ];
        // Sur une même ligne quand la place le permet, empilés sinon.
        return LayoutBuilder(
          builder: (context, constraints) => constraints.maxWidth < 600
              ? Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (final (i, field) in fields.indexed) ...[
                      if (i > 0) const SizedBox(height: 8),
                      field,
                    ],
                  ],
                )
              : Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    for (final (i, field) in fields.indexed) ...[
                      if (i > 0) const SizedBox(width: 12),
                      Expanded(child: field),
                    ],
                  ],
                ),
        );
      },
    );
  }
}
