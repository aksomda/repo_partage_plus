/// Contenu du QR code de retrait : réservation et code à 6 chiffres.
String pickupQrData(Object? reservationId, String code) =>
    'partageplus:r$reservationId:$code';

/// Code de retrait lu dans un QR code. Le QR d'une autre réservation est
/// refusé (null) ; un code seul à 6 chiffres est accepté.
String? pickupCodeFromQr(String raw, {Object? reservationId}) {
  final clean = raw.trim();
  final full = RegExp(r'^partageplus:r(\d+):(\d{6})$').firstMatch(clean);
  if (full != null) {
    if (reservationId != null && full.group(1) != '$reservationId') {
      return null;
    }
    return full.group(2);
  }
  return RegExp(r'^\d{6}$').hasMatch(clean) ? clean : null;
}
