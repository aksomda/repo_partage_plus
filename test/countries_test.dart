import 'package:flutter_test/flutter_test.dart';

import 'package:repo_partage_plus/core/countries/countries.dart';
import 'package:repo_partage_plus/core/countries/country_widgets.dart';

void main() {
  test('pays : drapeau, indicatif, opérateurs', () {
    final burkina = countryByCode('bf')!;
    expect(burkina.name, 'Burkina Faso');
    expect(burkina.flag, '🇧🇫');
    expect(burkina.dialCode, '226');
    expect(burkina.mobileMoneyOperators, [
      'ORANGE MONEY',
      'MOOV MONEY',
      'WAVE',
      'LIGDICASH',
      'SANK MONEY',
      'TELECEL MONEY',
      'WIZALL MONEY',
    ]);
    expect(countryByCode('IS')!.mobileMoneyOperators, isEmpty);
    expect(countries.map((c) => c.code).toSet(), hasLength(countries.length));
    expect(countries.length, greaterThan(230));
  });

  test('pays d’un numéro : indicatif le plus long, pays principal', () {
    expect(countryOfNumber('+226 73 29 05 54')!.code, 'BF');
    expect(countryOfNumber('+1 555 0100')!.code, 'US');
    expect(countryOfNumber('+44 20 7946 0000')!.code, 'GB');
    expect(countryOfNumber('+1 876 555 0100')!.code, 'JM');
    expect(
      countryOfNumber('+1 416 555 0100', preferred: countryByCode('CA'))!.code,
      'CA',
    );
    expect(countryOfNumber('73290554'), isNull);
  });

  test('téléphone : indicatif du pays détecté, sauf choix de l’usager', () {
    final phone = PhoneController();
    addTearDown(phone.dispose);

    phone.number.text = '73 29 05 54';
    expect(phone.value, '+226 73290554');

    phone.suggest(countryByCode('CI')!);
    expect(phone.value, '+225 73290554');

    phone.country = countryByCode('SN')!;
    phone.suggest(countryByCode('ML')!);
    expect(phone.value, '+221 73290554');

    phone.value = '+223 70 11 22 33';
    expect(phone.country.code, 'ML');
    expect(phone.number.text, '70112233');
  });

  test('comment payer : opérateur + numéro, relu à l’identique', () {
    final payment = PaymentInfoController();
    addTearDown(payment.dispose);

    payment.number.text = '73290554';
    payment.chooseOperator('ORANGE MONEY');
    expect(payment.paymentInfo, 'ORANGE MONEY : +226 73290554');

    // Changer de pays efface l'opérateur (propre à chaque pays).
    payment.country = countryByCode('SN')!;
    expect(payment.operator, isNull);

    payment.chooseOperator(PaymentInfoController.other);
    payment.otherOperator.text = 'Banque locale';
    expect(payment.paymentInfo, 'Banque locale : +221 73290554');

    final reread = PaymentInfoController();
    addTearDown(reread.dispose);
    reread.paymentInfo = 'WAVE : +225 0701020304';
    expect(reread.country.code, 'CI');
    expect(reread.operator, 'WAVE');
    expect(reread.paymentInfo, 'WAVE : +225 0701020304');
  });
}
