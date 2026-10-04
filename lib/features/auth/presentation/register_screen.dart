import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'package:repo_partage_plus/core/countries/country_widgets.dart';
import 'package:repo_partage_plus/core/offline/offline_data.dart';
import 'package:repo_partage_plus/core/router/app_routes.dart';
import 'package:repo_partage_plus/core/theme/app_theme.dart';
import 'package:repo_partage_plus/core/widgets/actor_icon.dart';
import 'package:repo_partage_plus/features/auth/data/auth_repository.dart';
import 'package:repo_partage_plus/features/auth/presentation/widgets/auth_widgets.dart';

/// Inscription en trois étapes : choix de l'acteur, informations, puis
/// vérification (champs non modifiables) avant validation et envoi du code.
class RegisterScreen extends ConsumerStatefulWidget {
  const RegisterScreen({super.key});

  @override
  ConsumerState<RegisterScreen> createState() => _RegisterScreenState();
}

class _RegisterScreenState extends ConsumerState<RegisterScreen> {
  final _details = GlobalKey<_DetailsStepState>();
  Json? _actor;

  void _back() {
    // Vérification : retour à la saisie, sans rien perdre.
    if (_details.currentState?.leaveReview() ?? false) return;
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
        if (!didPop) _back();
      },
      child: AuthLayout(
        title: 'Inscription',
        onBack: _back,
        // Formulaire : jusqu'à 4 colonnes de champs sur grand écran.
        maxWidth: _actor == null ? 440 : 1040,
        children: [
          if (_actor == null)
            _ActorStep(onSelected: (actor) => setState(() => _actor = actor))
          else
            _DetailsStep(key: _details, actor: _actor!),
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
  const _DetailsStep({super.key, required this.actor});

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
  final _phone = PhoneController();
  final _password = TextEditingController();
  final _confirm = TextEditingController();
  final _associationName = TextEditingController();
  final _associationNumber = TextEditingController();
  final _associationAddress = TextEditingController();
  String? _gender;
  var _genderError = false;
  var _loading = false;
  var _autovalidate = AutovalidateMode.disabled;

  /// Étape 3 : informations affichées sans modification possible.
  var _reviewing = false;

  bool get _isAssociation => widget.actor['permission_role'] == 'association';

  /// « Précédent » : retour à la saisie. false si on n'était pas en vérification.
  bool leaveReview() {
    if (!_reviewing || _loading) return _reviewing;
    setState(() => _reviewing = false);
    return true;
  }

  /// « Suivant » : vérifie la saisie puis affiche le récapitulatif.
  void _next() {
    // Après une première tentative, les erreurs se corrigent à la saisie.
    setState(() => _autovalidate = AutovalidateMode.onUserInteraction);
    final valid = _form.currentState!.validate();
    setState(() => _genderError = _gender == null);
    if (!valid || _gender == null) return;
    setState(() => _reviewing = true);
  }

  @override
  void dispose() {
    _phone.dispose();
    for (final controller in [
      _lastName,
      _firstName,
      _age,
      _email,
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

  /// « Valider » : crée le compte ; le serveur envoie le code d'activation.
  Future<void> _submit() async {
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
              phone: _phone.value,
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
    } on AccountExistsException catch (error) {
      if (!mounted) return;
      showMessage(context, error.toString());
      context.go(AppRoutes.loginWith(email));
    } catch (error) {
      if (mounted) showMessage(context, error.toString(), error: true);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_reviewing) return _review();
    return Form(
      key: _form,
      autovalidateMode: _autovalidate,
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
            FieldGrid(
              children: [
                LabeledField(
                  label: 'Nom',
                  required: true,
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
                  required: true,
                  child: TextFormField(
                    controller: _firstName,
                    textCapitalization: TextCapitalization.words,
                    textInputAction: TextInputAction.next,
                    autofillHints: const [AutofillHints.givenName],
                    decoration: const InputDecoration(hintText: 'Awa'),
                    validator: _name('Prénom'),
                  ),
                ),
                LabeledField(
                  label: 'Sexe',
                  required: true,
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
                  required: true,
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
                LabeledField(
                  label: 'Adresse e-mail',
                  required: true,
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
                  required: true,
                  child: PhoneField(
                    controller: _phone,
                    requiredMessage: 'Téléphone obligatoire',
                  ),
                ),
                if (_isAssociation) ..._associationFields(),
                LabeledField(
                  label: 'Mot de passe',
                  required: true,
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
                  required: true,
                  child: PasswordField(
                    controller: _confirm,
                    hint: 'Saisissez-le à nouveau',
                    textInputAction: TextInputAction.done,
                    onSubmitted: (_) => _next(),
                    validator: (value) {
                      if (value == null || value.isEmpty) {
                        return 'Confirmation obligatoire';
                      }
                      if (value != _password.text) {
                        return 'Les mots de passe ne correspondent pas';
                      }
                      return null;
                    },
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
                  child: FilledButton(
                    onPressed: _next,
                    child: const Text('Suivant'),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Récapitulatif non modifiable : « Précédent » pour corriger,
  /// « Valider » pour créer le compte et recevoir le code par e-mail.
  Widget _review() {
    final phone = _phone.value;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            ActorAvatar(actor: widget.actor, size: 40),
            const SizedBox(width: 12),
            Expanded(
              child: AuthHeading(
                title: 'Vérifiez vos informations',
                subtitle:
                    'Profil : ${widget.actor['label']}. Pour corriger, '
                    'revenez à l’étape précédente.',
              ),
            ),
          ],
        ),
        const SizedBox(height: 24),
        FieldGrid(
          children: [
            _ReadOnlyField('Nom', _lastName.text.trim()),
            _ReadOnlyField('Prénom', _firstName.text.trim()),
            _ReadOnlyField('Sexe', _gender == 'male' ? 'Homme' : 'Femme'),
            _ReadOnlyField('Âge', '${_age.text.trim()} ans'),
            _ReadOnlyField('Adresse e-mail', _email.text.trim().toLowerCase()),
            _ReadOnlyField('Téléphone', '${_phone.country.flag} $phone'),
            if (_isAssociation) ...[
              _ReadOnlyField(
                'Nom de l’association',
                _associationName.text.trim(),
              ),
              _ReadOnlyField(
                'N° d’enregistrement',
                _associationNumber.text.trim(),
              ),
              _ReadOnlyField('Adresse', _associationAddress.text.trim()),
            ],
            _ReadOnlyField('Mot de passe', '•' * _password.text.length),
          ],
        ),
        const SizedBox(height: 8),
        Text(
          'En validant, un code d’activation est envoyé à '
          '${_email.text.trim().toLowerCase()}.',
          textAlign: TextAlign.center,
          style: const TextStyle(color: AppColors.textMuted),
        ),
        const SizedBox(height: 16),
        Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 440),
            child: Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _loading ? null : leaveReview,
                    icon: const Icon(Icons.arrow_back),
                    label: const Text('Précédent'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: LoadingButton(
                    label: 'Valider',
                    loading: _loading,
                    onPressed: _submit,
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  List<Widget> _associationFields() => [
    LabeledField(
      label: 'Nom de l’association',
      required: true,
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
    if (!_namePattern.hasMatch(text)) return '$field invalide';
    return null;
  };

  /// Lettres (accents compris), espaces, tirets, apostrophes et points.
  static final _namePattern = RegExp(r"^[\p{L} .'’-]+$", unicode: true);
}

/// Valeur saisie, affichée sans pouvoir la modifier.
class _ReadOnlyField extends StatelessWidget {
  const _ReadOnlyField(this.label, this.value);

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return LabeledField(
      label: label,
      child: InputDecorator(
        decoration: const InputDecoration(enabled: false),
        child: Text(
          value.isEmpty ? '—' : value,
          style: const TextStyle(color: AppColors.text),
        ),
      ),
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
