import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'package:repo_partage_plus/core/router/app_routes.dart';
import 'package:repo_partage_plus/core/widgets/brand_logo.dart';
import 'package:repo_partage_plus/features/auth/data/auth_repository.dart';
import 'package:repo_partage_plus/features/auth/presentation/widgets/auth_widgets.dart';

/// Mot de passe oublié, sans l'aide d'un administrateur : un code à
/// 6 chiffres est envoyé par e-mail, puis l'utilisateur choisit un nouveau
/// mot de passe.
class ForgotPasswordScreen extends ConsumerStatefulWidget {
  const ForgotPasswordScreen({super.key, this.initialEmail = ''});

  final String initialEmail;

  @override
  ConsumerState<ForgotPasswordScreen> createState() =>
      _ForgotPasswordScreenState();
}

class _ForgotPasswordScreenState extends ConsumerState<ForgotPasswordScreen> {
  /// Délai imposé par le serveur entre deux envois.
  static const resendDelay = 60;

  final _form = GlobalKey<FormState>();
  late final _email = TextEditingController(text: widget.initialEmail.trim());
  final _code = TextEditingController();
  final _password = TextEditingController();
  final _confirm = TextEditingController();
  final _passwordFocus = FocusNode();
  var _codeSent = false;
  var _loading = false;
  var _resendIn = 0;
  Timer? _timer;

  String get _emailValue => _email.text.trim().toLowerCase();

  @override
  void dispose() {
    _timer?.cancel();
    _passwordFocus.dispose();
    for (final controller in [_email, _code, _password, _confirm]) {
      controller.dispose();
    }
    super.dispose();
  }

  void _startCountdown() {
    _timer?.cancel();
    setState(() => _resendIn = resendDelay);
    _timer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (_resendIn <= 1) timer.cancel();
      setState(() => _resendIn--);
    });
  }

  Future<void> _sendCode() async {
    final error = validateEmail(_email.text);
    if (error != null) {
      showMessage(context, error, error: true);
      return;
    }
    setState(() => _loading = true);
    try {
      await ref.read(authRepositoryProvider).requestPasswordReset(_emailValue);
      if (!mounted) return;
      setState(() => _codeSent = true);
      _startCountdown();
      showMessage(
        context,
        'Si un compte existe pour $_emailValue, un code vient d’y être '
        'envoyé',
      );
    } catch (error) {
      if (mounted) showMessage(context, error.toString(), error: true);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _reset() async {
    if (!_form.currentState!.validate()) return;
    setState(() => _loading = true);
    try {
      await ref
          .read(authRepositoryProvider)
          .resetPassword(
            email: _emailValue,
            code: _code.text.trim(),
            password: _password.text,
          );
      if (!mounted) return;
      showMessage(
        context,
        'Mot de passe modifié : connectez-vous avec le nouveau',
      );
      context.go(AppRoutes.login);
    } catch (error) {
      if (mounted) showMessage(context, error.toString(), error: true);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AuthLayout(
      title: 'Mot de passe oublié',
      showLogo: false,
      onBack: () =>
          context.canPop() ? context.pop() : context.go(AppRoutes.login),
      children: [
        const Center(child: BrandLogo.full(size: 100)),
        const SizedBox(height: 24),
        AuthHeading(
          title: 'Réinitialiser le mot de passe',
          subtitle: _codeSent
              ? 'Saisissez le code à 6 chiffres reçu par e-mail (pensez aux '
                    'spams), puis choisissez un nouveau mot de passe.'
              : 'Indiquez l’adresse e-mail de votre compte : vous recevrez '
                    'un code pour choisir un nouveau mot de passe.',
        ),
        const SizedBox(height: 24),
        Form(
          key: _form,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              LabeledField(
                label: 'Adresse e-mail',
                child: TextFormField(
                  controller: _email,
                  keyboardType: TextInputType.emailAddress,
                  autofillHints: const [AutofillHints.email],
                  textInputAction: _codeSent
                      ? TextInputAction.next
                      : TextInputAction.done,
                  decoration: const InputDecoration(
                    hintText: 'exemple@mail.com',
                  ),
                  onFieldSubmitted: (_) => _codeSent ? null : _sendCode(),
                  validator: validateEmail,
                ),
              ),
              if (_codeSent) ...[
                LabeledField(
                  label: 'Code reçu par e-mail',
                  child: TextFormField(
                    controller: _code,
                    autofocus: true,
                    keyboardType: TextInputType.number,
                    textAlign: TextAlign.center,
                    textInputAction: TextInputAction.next,
                    autofillHints: const [AutofillHints.oneTimeCode],
                    inputFormatters: [
                      FilteringTextInputFormatter.digitsOnly,
                      LengthLimitingTextInputFormatter(6),
                    ],
                    style: const TextStyle(
                      fontSize: 24,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 12,
                    ),
                    decoration: const InputDecoration(hintText: '••••••'),
                    validator: (value) => (value ?? '').length == 6
                        ? null
                        : 'Le code contient 6 chiffres',
                  ),
                ),
                LabeledField(
                  label: 'Nouveau mot de passe',
                  child: PasswordField(
                    controller: _password,
                    focusNode: _passwordFocus,
                    hint: '8 caractères, lettres et chiffres',
                    textInputAction: TextInputAction.next,
                    autofillHints: const [AutofillHints.newPassword],
                    validator: validatePassword,
                  ),
                ),
                LabeledField(
                  label: 'Confirmer le mot de passe',
                  child: ConfirmPasswordField(
                    password: _password,
                    controller: _confirm,
                    passwordFocus: _passwordFocus,
                    hint: 'Le même mot de passe',
                    onSubmitted: (_) => _reset(),
                  ),
                ),
              ],
            ],
          ),
        ),
        const SizedBox(height: 8),
        if (_codeSent) ...[
          LoadingButton(
            label: 'Changer le mot de passe',
            loading: _loading,
            onPressed: _reset,
          ),
          const SizedBox(height: 16),
          Center(
            child: TextButton.icon(
              onPressed: _resendIn > 0 || _loading ? null : _sendCode,
              icon: const Icon(Icons.refresh, size: 18),
              label: Text(
                _resendIn > 0
                    ? 'Renvoyer le code (${_resendIn}s)'
                    : 'Renvoyer le code',
              ),
            ),
          ),
        ] else
          LoadingButton(
            label: 'Recevoir un code',
            loading: _loading,
            onPressed: _sendCode,
          ),
      ],
    );
  }
}
