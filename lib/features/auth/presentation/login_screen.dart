import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'package:repo_partage_plus/core/router/app_routes.dart';
import 'package:repo_partage_plus/core/storage/local_store.dart';
import 'package:repo_partage_plus/features/auth/data/auth_repository.dart';
import 'package:repo_partage_plus/features/auth/presentation/widgets/auth_widgets.dart';

class LoginScreen extends ConsumerStatefulWidget {
  const LoginScreen({super.key, this.from, this.initialEmail});

  /// Écran demandé avant la redirection vers la connexion.
  final String? from;

  /// Adresse pré-remplie (ex. retour d'une inscription sur un compte existant).
  final String? initialEmail;

  @override
  ConsumerState<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends ConsumerState<LoginScreen> {
  final _form = GlobalKey<FormState>();
  late final _email = TextEditingController(text: widget.initialEmail ?? '');
  final _password = TextEditingController();
  var _loading = false;

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_form.currentState!.validate()) return;
    setState(() => _loading = true);
    final email = _email.text.trim();

    try {
      await ref.read(authRepositoryProvider).login(email, _password.text);
      final profile = await ref
          .read(localStoreProvider)
          .readSnapshot('profile');
      if (!mounted) return;
      context.go(widget.from ?? AppRoutes.homeFor(profile));
    } on AccountPendingException catch (error) {
      if (!mounted) return;
      showMessage(context, error.toString());
      context.push(AppRoutes.verifyEmailFor(error.email));
    } catch (error) {
      if (mounted) showMessage(context, error.toString(), error: true);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  /// Code par e-mail puis nouveau mot de passe, sans aide d'un administrateur.
  void _forgotPassword() =>
      context.push(AppRoutes.forgotPasswordFor(_email.text.trim()));

  @override
  Widget build(BuildContext context) {
    return AuthLayout(
      onBack: () =>
          context.canPop() ? context.pop() : context.go(AppRoutes.home),
      children: [
        const AuthHeading(
          title: 'Connexion',
          subtitle: 'Accédez à votre compte',
        ),
        const SizedBox(height: 24),
        Form(
          key: _form,
          child: AutofillGroup(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                LabeledField(
                  label: 'Adresse e-mail',
                  child: TextFormField(
                    controller: _email,
                    keyboardType: TextInputType.emailAddress,
                    textInputAction: TextInputAction.next,
                    autofillHints: const [AutofillHints.email],
                    decoration: const InputDecoration(
                      hintText: 'exemple@mail.com',
                    ),
                    validator: validateEmail,
                  ),
                ),
                LabeledField(
                  label: 'Mot de passe',
                  child: PasswordField(
                    controller: _password,
                    textInputAction: TextInputAction.done,
                    autofillHints: const [AutofillHints.password],
                    onSubmitted: (_) => _submit(),
                    validator: requiredField('Mot de passe obligatoire'),
                  ),
                ),
              ],
            ),
          ),
        ),
        Align(
          alignment: Alignment.centerRight,
          child: TextButton(
            onPressed: _forgotPassword,
            child: const Text('Mot de passe oublié ?'),
          ),
        ),
        const SizedBox(height: 8),
        LoadingButton(
          label: 'Se connecter',
          loading: _loading,
          onPressed: _submit,
        ),
        const SizedBox(height: 16),
        AuthFooterLink(
          question: 'Pas encore de compte ?',
          action: 'S’inscrire',
          onTap: () => context.pushReplacement(AppRoutes.register),
        ),
        AuthFooterLink(
          question: 'Code d’activation reçu ?',
          action: 'Activer mon compte',
          onTap: () =>
              context.push(AppRoutes.verifyEmailFor(_email.text.trim())),
        ),
      ],
    );
  }
}
