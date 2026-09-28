import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'package:repo_partage_plus/core/offline/offline_data.dart';
import 'package:repo_partage_plus/core/router/app_routes.dart';
import 'package:repo_partage_plus/core/theme/app_theme.dart';
import 'package:repo_partage_plus/core/widgets/actor_icon.dart';
import 'package:repo_partage_plus/features/auth/data/auth_repository.dart';
import 'package:repo_partage_plus/features/auth/presentation/widgets/auth_widgets.dart';

/// Inscription en deux étapes : choix de l'acteur, puis informations.
class RegisterScreen extends ConsumerStatefulWidget {
  const RegisterScreen({super.key});

  @override
  ConsumerState<RegisterScreen> createState() => _RegisterScreenState();
}

class _RegisterScreenState extends ConsumerState<RegisterScreen> {
  Json? _actor;

  void _back() {
    if (_actor != null) {
      setState(() => _actor = null);
    } else if (context.canPop()) {
      context.pop();
    } else {
      context.go(AppRoutes.splash);
    }
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: _actor == null,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) setState(() => _actor = null);
      },
      child: AuthLayout(
        title: 'Inscription',
        onBack: _back,
        children: [
          if (_actor == null)
            _ActorStep(onSelected: (actor) => setState(() => _actor = actor))
          else
            _DetailsStep(actor: _actor!),
        ],
      ),
    );
  }
}

// ---------- Étape 1 : choix de l'acteur ----------

class _ActorStep extends ConsumerWidget {
  const _ActorStep({required this.onSelected});

  final ValueChanged<Json> onSelected;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final actors = ref.watch(signupActorsProvider);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const AuthHeading(
          title: 'Choisissez votre rôle',
          subtitle: 'Quel est votre profil ?',
        ),
        const SizedBox(height: 24),
        ...actors.when(
          data: (list) => [
            for (final actor in list)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: _ActorCard(actor: actor, onTap: () => onSelected(actor)),
              ),
            if (list.isEmpty)
              const Text('Aucun profil n’est ouvert à l’inscription.'),
          ],
          loading: () => const [
            Padding(
              padding: EdgeInsets.all(32),
              child: Center(child: CircularProgressIndicator()),
            ),
          ],
          error: (error, _) => [
            Text(
              error.toString(),
              textAlign: TextAlign.center,
              style: const TextStyle(color: AppColors.danger),
            ),
            const SizedBox(height: 12),
            OutlinedButton(
              onPressed: () => ref.invalidate(signupActorsProvider),
              child: const Text('Réessayer'),
            ),
          ],
        ),
        const SizedBox(height: 8),
        AuthFooterLink(
          question: 'Déjà un compte ?',
          action: 'Se connecter',
          onTap: () => context.pushReplacement(AppRoutes.login),
        ),
      ],
    );
  }
}

class _ActorCard extends StatelessWidget {
  const _ActorCard({required this.actor, required this.onTap});

  final Json actor;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final description = actor['description'] as String?;
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              ActorAvatar(actor: actor),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      actor['label'] as String,
                      style: const TextStyle(
                        fontWeight: FontWeight.w700,
                        fontSize: 16,
                      ),
                    ),
                    if (description != null && description.isNotEmpty) ...[
                      const SizedBox(height: 2),
                      Text(
                        description,
                        style: const TextStyle(color: AppColors.textMuted),
                      ),
                    ],
                  ],
                ),
              ),
              const Icon(Icons.chevron_right, color: AppColors.textMuted),
            ],
          ),
        ),
      ),
    );
  }
}

// ---------- Étape 2 : informations personnelles ----------

class _DetailsStep extends ConsumerStatefulWidget {
  const _DetailsStep({required this.actor});

  final Json actor;

  @override
  ConsumerState<_DetailsStep> createState() => _DetailsStepState();
}

class _DetailsStepState extends ConsumerState<_DetailsStep> {
  final _form = GlobalKey<FormState>();
  final _lastName = TextEditingController();
  final _firstName = TextEditingController();
  final _age = TextEditingController();
  final _email = TextEditingController();
  final _phone = TextEditingController();
  final _password = TextEditingController();
  final _confirm = TextEditingController();
  final _associationName = TextEditingController();
  final _associationNumber = TextEditingController();
  final _associationAddress = TextEditingController();
  String? _gender;
  var _genderError = false;
  var _loading = false;

  bool get _isAssociation => widget.actor['permission_role'] == 'association';

  @override
  void dispose() {
    for (final controller in [
      _lastName,
      _firstName,
      _age,
      _email,
      _phone,
      _password,
      _confirm,
      _associationName,
      _associationNumber,
      _associationAddress,
    ]) {
      controller.dispose();
    }
    super.dispose();
  }

  Future<void> _submit() async {
    final valid = _form.currentState!.validate();
    setState(() => _genderError = _gender == null);
    if (!valid || _gender == null) return;

    setState(() => _loading = true);
    final email = _email.text.trim().toLowerCase();
    try {
      await ref
          .read(authRepositoryProvider)
          .register(
            Registration(
              actorId: widget.actor['id'] as int,
              lastName: _lastName.text.trim(),
              firstName: _firstName.text.trim(),
              gender: _gender!,
              age: int.parse(_age.text.trim()),
              email: email,
              phone: _phone.text.trim(),
              password: _password.text,
              association: _isAssociation
                  ? {
                      'name': _associationName.text.trim(),
                      if (_associationNumber.text.trim().isNotEmpty)
                        'registration_number': _associationNumber.text.trim(),
                      if (_associationAddress.text.trim().isNotEmpty)
                        'address': _associationAddress.text.trim(),
                    }
                  : null,
            ),
          );
      if (!mounted) return;
      showMessage(context, 'Un code d’activation a été envoyé à $email');
      context.go(AppRoutes.verifyEmailFor(email));
    } catch (error) {
      if (mounted) showMessage(context, error.toString(), error: true);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Form(
      key: _form,
      child: AutofillGroup(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                ActorAvatar(actor: widget.actor, size: 40),
                const SizedBox(width: 12),
                Expanded(
                  child: AuthHeading(
                    title: 'Vos informations',
                    subtitle: 'Profil : ${widget.actor['label']}',
                  ),
                ),
              ],
            ),
            const SizedBox(height: 24),
            _twoColumns(
              LabeledField(
                label: 'Nom',
                child: TextFormField(
                  controller: _lastName,
                  textCapitalization: TextCapitalization.words,
                  textInputAction: TextInputAction.next,
                  autofillHints: const [AutofillHints.familyName],
                  decoration: const InputDecoration(hintText: 'Ouédraogo'),
                  validator: _name('Nom'),
                ),
              ),
              LabeledField(
                label: 'Prénom',
                child: TextFormField(
                  controller: _firstName,
                  textCapitalization: TextCapitalization.words,
                  textInputAction: TextInputAction.next,
                  autofillHints: const [AutofillHints.givenName],
                  decoration: const InputDecoration(hintText: 'Awa'),
                  validator: _name('Prénom'),
                ),
              ),
            ),
            _twoColumns(
              LabeledField(
                label: 'Sexe',
                child: _GenderSelector(
                  value: _gender,
                  error: _genderError,
                  onChanged: (value) => setState(() {
                    _gender = value;
                    _genderError = false;
                  }),
                ),
              ),
              LabeledField(
                label: 'Âge',
                child: TextFormField(
                  controller: _age,
                  keyboardType: TextInputType.number,
                  textInputAction: TextInputAction.next,
                  inputFormatters: [
                    FilteringTextInputFormatter.digitsOnly,
                    LengthLimitingTextInputFormatter(3),
                  ],
                  decoration: const InputDecoration(
                    hintText: '25',
                    suffixText: 'ans',
                  ),
                  validator: (value) {
                    final age = int.tryParse(value ?? '');
                    if (age == null) return 'Âge obligatoire';
                    if (age < 13) return '13 ans minimum';
                    if (age > 120) return 'Âge invalide';
                    return null;
                  },
                ),
              ),
            ),
            LabeledField(
              label: 'Adresse e-mail',
              child: TextFormField(
                controller: _email,
                keyboardType: TextInputType.emailAddress,
                textInputAction: TextInputAction.next,
                autofillHints: const [AutofillHints.email],
                decoration: const InputDecoration(
                  hintText: 'exemple@mail.com',
                  helperText: 'Un code d’activation vous y sera envoyé',
                ),
                validator: validateEmail,
              ),
            ),
            LabeledField(
              label: 'Téléphone',
              child: TextFormField(
                controller: _phone,
                keyboardType: TextInputType.phone,
                textInputAction: TextInputAction.next,
                autofillHints: const [AutofillHints.telephoneNumber],
                inputFormatters: [
                  FilteringTextInputFormatter.allow(RegExp(r'[0-9+ ]')),
                ],
                decoration: const InputDecoration(hintText: '+226 70 00 00 00'),
                validator: (value) {
                  final phone = value?.trim() ?? '';
                  if (phone.isEmpty) return 'Téléphone obligatoire';
                  if (!RegExp(r'^\+?[0-9 ]{8,20}$').hasMatch(phone)) {
                    return 'Numéro invalide';
                  }
                  return null;
                },
              ),
            ),
            if (_isAssociation) ..._associationFields(),
            LabeledField(
              label: 'Mot de passe',
              child: PasswordField(
                controller: _password,
                hint: '8 caractères, lettres et chiffres',
                textInputAction: TextInputAction.next,
                autofillHints: const [AutofillHints.newPassword],
                validator: validatePassword,
              ),
            ),
            LabeledField(
              label: 'Confirmer le mot de passe',
              child: PasswordField(
                controller: _confirm,
                hint: 'Saisissez-le à nouveau',
                textInputAction: TextInputAction.done,
                onSubmitted: (_) => _submit(),
                validator: (value) => value != _password.text
                    ? 'Les mots de passe ne correspondent pas'
                    : null,
              ),
            ),
            const SizedBox(height: 8),
            LoadingButton(
              label: 'Créer mon compte',
              loading: _loading,
              onPressed: _submit,
            ),
          ],
        ),
      ),
    );
  }

  List<Widget> _associationFields() => [
    LabeledField(
      label: 'Nom de l’association',
      child: TextFormField(
        controller: _associationName,
        textInputAction: TextInputAction.next,
        validator: requiredField('Nom de l’association obligatoire'),
      ),
    ),
    LabeledField(
      label: 'N° d’enregistrement (facultatif)',
      child: TextFormField(
        controller: _associationNumber,
        textInputAction: TextInputAction.next,
      ),
    ),
    LabeledField(
      label: 'Adresse (facultatif)',
      child: TextFormField(
        controller: _associationAddress,
        textInputAction: TextInputAction.next,
      ),
    ),
  ];

  static String? Function(String?) _name(String field) => (value) {
    final text = value?.trim() ?? '';
    if (text.isEmpty) return '$field obligatoire';
    if (text.length < 2) return '2 caractères minimum';
    return null;
  };

  /// Deux champs côte à côte, empilés sur les écrans étroits.
  Widget _twoColumns(Widget first, Widget second) {
    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth < 340) {
          return Column(children: [first, second]);
        }
        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(child: first),
            const SizedBox(width: 12),
            Expanded(child: second),
          ],
        );
      },
    );
  }
}

class _GenderSelector extends StatelessWidget {
  const _GenderSelector({
    required this.value,
    required this.error,
    required this.onChanged,
  });

  final String? value;
  final bool error;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    Widget option(String code, String label) {
      final selected = value == code;
      return Expanded(
        child: ChoiceChip(
          label: SizedBox(
            width: double.infinity,
            child: Text(label, textAlign: TextAlign.center),
          ),
          selected: selected,
          onSelected: (_) => onChanged(code),
          labelStyle: TextStyle(
            color: selected ? Colors.white : AppColors.text,
            fontWeight: FontWeight.w600,
          ),
          side: BorderSide(color: error ? AppColors.danger : AppColors.border),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppTheme.radius),
          ),
          padding: const EdgeInsets.symmetric(vertical: 10),
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            option('male', 'Homme'),
            const SizedBox(width: 8),
            option('female', 'Femme'),
          ],
        ),
        if (error)
          const Padding(
            padding: EdgeInsets.only(top: 6, left: 12),
            child: Text(
              'Sexe obligatoire',
              style: TextStyle(color: AppColors.danger, fontSize: 12),
            ),
          ),
      ],
    );
  }
}
