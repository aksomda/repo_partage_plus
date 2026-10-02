import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'package:repo_partage_plus/core/guest/guest_repository.dart';
import 'package:repo_partage_plus/core/router/app_routes.dart';
import 'package:repo_partage_plus/core/theme/app_theme.dart';
import 'package:repo_partage_plus/features/auth/presentation/widgets/auth_widgets.dart';

/// Contrôleurs des champs d'identité d'un invité.
class GuestFieldsController {
  final firstName = TextEditingController();
  final lastName = TextEditingController();
  final phone = TextEditingController();

  GuestIdentity get value => GuestIdentity(
    firstName: firstName.text.trim(),
    lastName: lastName.text.trim(),
    phone: phone.text.trim(),
  );

  void fill(GuestIdentity? identity) {
    if (identity == null || firstName.text.isNotEmpty) return;
    firstName.text = identity.firstName;
    lastName.text = identity.lastName;
    phone.text = identity.phone;
  }

  void dispose() {
    firstName.dispose();
    lastName.dispose();
    phone.dispose();
  }
}

/// Nom, prénom et téléphone d'une personne sans compte, pré-remplis avec la
/// dernière identité utilisée sur l'appareil. [notice] explique l'usage.
class GuestFields extends ConsumerWidget {
  const GuestFields({
    super.key,
    required this.controller,
    required this.notice,
    this.returnTo,
  });

  final GuestFieldsController controller;
  final String notice;

  /// Écran où revenir après une connexion proposée ici.
  final String? returnTo;

  static String? _name(String? value) =>
      (value?.trim().length ?? 0) < 2 ? '2 caractères minimum' : null;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.watch(guestIdentityProvider).whenData(controller.fill);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          padding: const EdgeInsets.all(12),
          margin: const EdgeInsets.only(bottom: 16),
          decoration: BoxDecoration(
            color: AppColors.primarySoft,
            borderRadius: BorderRadius.circular(AppTheme.radius),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(notice),
              TextButton(
                style: TextButton.styleFrom(padding: EdgeInsets.zero),
                onPressed: () => context.push(
                  returnTo == null
                      ? AppRoutes.login
                      : AppRoutes.loginThen(returnTo!),
                ),
                child: const Text('J’ai un compte : me connecter'),
              ),
            ],
          ),
        ),
        FieldGrid(
          children: [
            LabeledField(
              label: 'Nom',
              required: true,
              child: TextFormField(
                controller: controller.lastName,
                textCapitalization: TextCapitalization.words,
                textInputAction: TextInputAction.next,
                validator: _name,
              ),
            ),
            LabeledField(
              label: 'Prénom',
              required: true,
              child: TextFormField(
                controller: controller.firstName,
                textCapitalization: TextCapitalization.words,
                textInputAction: TextInputAction.next,
                validator: _name,
              ),
            ),
            LabeledField(
              label: 'Téléphone',
              required: true,
              child: TextFormField(
                controller: controller.phone,
                keyboardType: TextInputType.phone,
                textInputAction: TextInputAction.next,
                inputFormatters: [
                  FilteringTextInputFormatter.allow(RegExp(r'[0-9+ ]')),
                ],
                decoration: const InputDecoration(hintText: '+226 70 00 00 00'),
                validator: (value) =>
                    RegExp(r'^\+?[0-9 ]{8,20}$').hasMatch(value?.trim() ?? '')
                    ? null
                    : 'Numéro invalide',
              ),
            ),
          ],
        ),
      ],
    );
  }
}
