import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import 'package:repo_partage_plus/core/offline/offline_data.dart';
import 'package:repo_partage_plus/core/offline/sync_controller.dart';
import 'package:repo_partage_plus/core/router/app_routes.dart';
import 'package:repo_partage_plus/core/theme/app_theme.dart';
import 'package:repo_partage_plus/features/auth/presentation/widgets/auth_widgets.dart';
import 'package:repo_partage_plus/features/offers/presentation/widgets/offer_widgets.dart';
import 'package:repo_partage_plus/features/reservations/data/reservations_repository.dart';

/// Provider pour récupérer la réservation concernée (reçue ou personnelle) par son ID.
final lookupReservationProvider = Provider.family<Json?, int>((ref, id) {
  final received = ref.watch(receivedReservationsProvider);
  for (final item in received) {
    if (item['id'] == id) return item;
  }
  final mine = ref.watch(myReservationsProvider);
  for (final item in mine) {
    if (item['id'] == id) return item;
  }
  return null;
});

/// Écran de validation du retrait d'une commande par le donateur (Commerçant / Restaurant).
/// Propose la saisie manuelle du code à 6 chiffres et le scanner de QR Code via caméra.
class PickupScreen extends ConsumerStatefulWidget {
  const PickupScreen({super.key, required this.reservationId});

  final String reservationId;

  @override
  ConsumerState<PickupScreen> createState() => _PickupScreenState();
}

enum _ValidationMode { manual, qrCode }

class _PickupScreenState extends ConsumerState<PickupScreen> {
  final _formKey = GlobalKey<FormState>();
  final _codeController = TextEditingController();
  final MobileScannerController _scannerController = MobileScannerController(
    detectionSpeed: DetectionSpeed.noDuplicates,
    facing: CameraFacing.back,
  );

  var _mode = _ValidationMode.manual;
  var _loading = false;
  var _torchOn = false;

  @override
  void dispose() {
    _codeController.dispose();
    _scannerController.dispose();
    super.dispose();
  }

  /// Extrait un code à 6 chiffres d'une chaîne scannée (raw string ou JSON).
  String? _extractCode(String raw) {
    final clean = raw.trim();
    final match = RegExp(r'\b\d{6}\b').firstMatch(clean);
    return match?.group(0);
  }

  Future<void> _submitPickup(Json reservation, String pickupCode) async {
    if (_loading) return;

    setState(() => _loading = true);
    HapticFeedback.mediumImpact();

    try {
      final result = await ref
          .read(reservationsRepositoryProvider)
          .validatePickup(reservation, pickupCode);

      if (!mounted) return;

      switch (result) {
        case Sent():
          showMessage(context, 'Retrait validé avec succès !');
          context.go(AppRoutes.myReservations);
        case Queued():
          showMessage(
            context,
            'Hors ligne : retrait enregistré, sera synchronisé au retour du réseau',
          );
          context.go(AppRoutes.myReservations);
        case Rejected(:final message):
          showMessage(
            context,
            'Validation échouée : $message',
            error: true,
          );
      }
    } catch (e) {
      if (mounted) showMessage(context, e.toString(), error: true);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _onQrDetected(BarcodeCapture capture, Json reservation) {
    if (_loading) return;

    for (final barcode in capture.barcodes) {
      final rawValue = barcode.rawValue;
      if (rawValue == null) continue;

      final code = _extractCode(rawValue);
      if (code != null) {
        _codeController.text = code;
        _submitPickup(reservation, code);
        break;
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final id = int.tryParse(widget.reservationId);
    final reservation = id == null ? null : ref.watch(lookupReservationProvider(id));

    return Scaffold(
      appBar: AppBar(
        title: const Text('Valider le retrait'),
        actions: [
          if (_mode == _ValidationMode.qrCode)
            IconButton(
              tooltip: 'Lampe de poche',
              icon: Icon(
                _torchOn ? Icons.flash_on : Icons.flash_off,
                color: _torchOn ? AppColors.accent : null,
              ),
              onPressed: () async {
                await _scannerController.toggleTorch();
                setState(() => _torchOn = !_torchOn);
              },
            ),
        ],
      ),
      body: reservation == null
          ? Center(
              child: EmptyState(
                icon: Icons.search_off,
                title: 'Réservation introuvable',
                message: 'La réservation n° ${widget.reservationId} est introuvable.',
                action: OutlinedButton(
                  onPressed: () => context.go(AppRoutes.myReservations),
                  child: const Text('Retour aux commandes'),
                ),
              ),
            )
          : Column(
              children: [
                _HeaderSummary(reservation: reservation),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  child: SegmentedButton<_ValidationMode>(
                    segments: const [
                      ButtonSegment(
                        value: _ValidationMode.manual,
                        label: Text('Code manuel'),
                        icon: Icon(Icons.pin),
                      ),
                      ButtonSegment(
                        value: _ValidationMode.qrCode,
                        label: Text('Scanner QR Code'),
                        icon: Icon(Icons.qr_code_scanner),
                      ),
                    ],
                    selected: {_mode},
                    onSelectionChanged: (selected) {
                      setState(() {
                        _mode = selected.first;
                      });
                    },
                  ),
                ),
                Expanded(
                  child: AnimatedSwitcher(
                    duration: const Duration(milliseconds: 250),
                    child: _mode == _ValidationMode.manual
                        ? _ManualInputView(
                            key: const ValueKey('manual'),
                            formKey: _formKey,
                            codeController: _codeController,
                            loading: _loading,
                            onSubmit: () {
                              if (_formKey.currentState!.validate()) {
                                _submitPickup(
                                  reservation,
                                  _codeController.text.trim(),
                                );
                              }
                            },
                          )
                        : _QrScannerView(
                            key: const ValueKey('qr'),
                            scannerController: _scannerController,
                            loading: _loading,
                            onDetect: (capture) => _onQrDetected(capture, reservation),
                          ),
                  ),
                ),
              ],
            ),
    );
  }
}

/// En-tête récapitulatif de la commande pour le donateur.
class _HeaderSummary extends StatelessWidget {
  const _HeaderSummary({required this.reservation});

  final Json reservation;

  @override
  Widget build(BuildContext context) {
    final offerTitle = reservation['offer_title'] as String? ?? 'Offre';
    final beneficiaryName =
        reservation['beneficiary_name'] as String? ?? 'Bénéficiaire';
    final quantity = reservation['quantity'] as num? ?? 1;
    final status = reservation['status'] as String? ?? 'confirmed';

    return Container(
      padding: const EdgeInsets.all(16),
      color: AppColors.surface,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  offerTitle,
                  style: const TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 17,
                  ),
                ),
              ),
              StatusBadge(status),
            ],
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              const Icon(Icons.person_outline, size: 16, color: AppColors.textMuted),
              const SizedBox(width: 6),
              Text(
                'Client : $beneficiaryName',
                style: const TextStyle(
                  color: AppColors.textMuted,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const Spacer(),
              const Icon(Icons.inventory_2_outlined, size: 16, color: AppColors.textMuted),
              const SizedBox(width: 6),
              Text(
                'Qté : $quantity',
                style: const TextStyle(color: AppColors.textMuted),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Vue de saisie manuelle du code à 6 chiffres.
class _ManualInputView extends StatelessWidget {
  const _ManualInputView({
    super.key,
    required this.formKey,
    required this.codeController,
    required this.loading,
    required this.onSubmit,
  });

  final GlobalKey<FormState> formKey;
  final TextEditingController codeController;
  final bool loading;
  final VoidCallback onSubmit;

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: Form(
        key: formKey,
        child: Column(
          children: [
            const Icon(
              Icons.dialpad,
              size: 56,
              color: AppColors.primary,
            ),
            const SizedBox(height: 12),
            const Text(
              'Code de retrait',
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 6),
            const Text(
              'Saisissez le code à 6 chiffres présenté par le client.',
              textAlign: TextAlign.center,
              style: TextStyle(color: AppColors.textMuted),
            ),
            const SizedBox(height: 24),
            TextFormField(
              controller: codeController,
              keyboardType: TextInputType.number,
              textAlign: TextAlign.center,
              autofocus: true,
              style: const TextStyle(
                fontSize: 32,
                fontWeight: FontWeight.bold,
                letterSpacing: 10,
                color: AppColors.primary,
              ),
              inputFormatters: [
                FilteringTextInputFormatter.digitsOnly,
                LengthLimitingTextInputFormatter(6),
              ],
              decoration: const InputDecoration(
                hintText: '000000',
                hintStyle: TextStyle(
                  fontSize: 32,
                  letterSpacing: 10,
                  color: AppColors.border,
                ),
              ),
              validator: (value) {
                final text = value?.trim() ?? '';
                if (text.length != 6) {
                  return 'Le code doit comporter exactement 6 chiffres';
                }
                return null;
              },
            ),
            const SizedBox(height: 28),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: loading ? null : onSubmit,
                icon: loading
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white,
                        ),
                      )
                    : const Icon(Icons.check_circle),
                label: Text(
                  loading ? 'Validation en cours...' : 'Valider le retrait',
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Vue du scanner de QR Code utilisant la caméra.
class _QrScannerView extends StatelessWidget {
  const _QrScannerView({
    super.key,
    required this.scannerController,
    required this.loading,
    required this.onDetect,
  });

  final MobileScannerController scannerController;
  final bool loading;
  final void Function(BarcodeCapture) onDetect;

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        MobileScanner(
          controller: scannerController,
          onDetect: onDetect,
        ),
        Center(
          child: Container(
            width: 240,
            height: 240,
            decoration: BoxDecoration(
              border: Border.all(color: AppColors.primary, width: 3),
              borderRadius: BorderRadius.circular(AppTheme.radius),
            ),
          ),
        ),
        Positioned(
          bottom: 24,
          left: 20,
          right: 20,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            decoration: BoxDecoration(
              color: Colors.black87,
              borderRadius: BorderRadius.circular(AppTheme.radius),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                if (loading)
                  const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Colors.white,
                    ),
                  )
                else
                  const Icon(
                    Icons.center_focus_strong,
                    color: Colors.white,
                    size: 20,
                  ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    loading
                        ? 'Validation du code...'
                        : 'Pointez la caméra vers le QR Code du client',
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}
