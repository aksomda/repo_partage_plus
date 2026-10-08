import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'package:repo_partage_plus/core/notifications/push_messaging.dart';
import 'package:repo_partage_plus/core/router/app_routes.dart';
import 'package:repo_partage_plus/core/storage/local_store.dart';
import 'package:repo_partage_plus/core/widgets/brand_logo.dart';
import 'package:repo_partage_plus/features/auth/data/auth_repository.dart';
import 'package:repo_partage_plus/features/auth/presentation/widgets/auth_widgets.dart';

/// Activation du compte : adresse e-mail + code à 6 chiffres reçu par e-mail
/// après l'inscription. Une fois le code validé, l'utilisateur est connecté.
class VerifyEmailScreen extends ConsumerStatefulWidget {
  const VerifyEmailScreen({super.key, this.initialEmail = ''});

  final String initialEmail;

  @override
  ConsumerState<VerifyEmailScreen> createState() => _VerifyEmailScreenState();
}

class _VerifyEmailScreenState extends ConsumerState<VerifyEmailScreen> {
  /// Délai imposé par le serveur entre deux envois.
  static const resendDelay = 60;

  final _form = GlobalKey<FormState>();
  late final _email = TextEditingController(text: widget.initialEmail);
  final _code = TextEditingController();
  var _loading = false;
  var _resendIn = 0;
  Timer? _timer;
  StreamSubscription<PushedCode>? _pushedCodes;

  @override
  void initState() {
    super.initState();
    // Code reçu par notification sur ce téléphone : champ rempli tout seul.
    _pushedCodes = ref
        .read(pushMessagingProvider)
        .codes
        .where((pushed) => pushed.purpose == 'activation')
        .listen((pushed) {
          if (!mounted) return;
          _code.text = pushed.code;
          showMessage(
            context,
            'Code reçu par notification : vérifiez et validez',
          );
        });
    // Arrivée juste après l'inscription : un code vient d'être envoyé.
    if (widget.initialEmail.isNotEmpty) _startCountdown();
  }

  @override
  void dispose() {
    _timer?.cancel();
    _pushedCodes?.cancel();
    _email.dispose();
    _code.dispose();
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

  Future<void> _submit() async {
    if (!_form.currentState!.validate()) return;
    setState(() => _loading = true);
    try {
      await ref
          .read(authRepositoryProvider)
          .verifyEmail(_email.text.trim().toLowerCase(), _code.text.trim());
      final profile = await ref
          .read(localStoreProvider)
          .readSnapshot('profile');
      if (!mounted) return;
      showMessage(context, 'Compte activé : bienvenue sur Partage+ !');
      context.go(AppRoutes.homeFor(profile));
    } catch (error) {
      if (mounted) showMessage(context, error.toString(), error: true);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _resend() async {
    final error = validateEmail(_email.text);
    if (error != null) {
      showMessage(context, error, error: true);
      return;
    }
    try {
      await ref
          .read(authRepositoryProvider)
          .resendCode(_email.text.trim().toLowerCase());
      if (!mounted) return;
      showMessage(context, 'Nouveau code envoyé à ${_email.text.trim()}');
      _startCountdown();
    } catch (error) {
      if (mounted) showMessage(context, error.toString(), error: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AuthLayout(
      title: 'Activation du compte',
      // Le logo remplace le pictogramme pour garder le bouton visible.
      showLogo: false,
      onBack: () =>
          context.canPop() ? context.pop() : context.go(AppRoutes.login),
      children: [
        const Center(child: BrandLogo.full(size: 100)),
        const SizedBox(height: 24),
        const AuthHeading(
          title: 'Vérifiez votre e-mail',
          subtitle:
              'Saisissez le code à 6 chiffres reçu par e-mail, SMS ou '
              'notification. Pensez aux spams.',
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
                  textInputAction: TextInputAction.next,
                  decoration: const InputDecoration(
                    hintText: 'exemple@mail.com',
                  ),
                  validator: validateEmail,
                ),
              ),
              LabeledField(
                label: 'Code d’activation',
                child: TextFormField(
                  controller: _code,
                  autofocus: widget.initialEmail.isNotEmpty,
                  keyboardType: TextInputType.number,
                  textAlign: TextAlign.center,
                  textInputAction: TextInputAction.done,
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
                  onFieldSubmitted: (_) => _submit(),
                  validator: (value) => (value ?? '').length == 6
                      ? null
                      : 'Le code contient 6 chiffres',
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 8),
        LoadingButton(
          label: 'Activer mon compte',
          loading: _loading,
          onPressed: _submit,
        ),
        const SizedBox(height: 16),
        Center(
          child: TextButton.icon(
            onPressed: _resendIn > 0 ? null : _resend,
            icon: const Icon(Icons.refresh, size: 18),
            label: Text(
              _resendIn > 0
                  ? 'Renvoyer le code (${_resendIn}s)'
                  : 'Renvoyer le code',
            ),
          ),
        ),
      ],
    );
  }
}
