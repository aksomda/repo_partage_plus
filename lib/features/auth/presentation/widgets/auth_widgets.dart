import 'package:flutter/material.dart';

import 'package:repo_partage_plus/core/theme/app_theme.dart';
import 'package:repo_partage_plus/core/widgets/brand_logo.dart';

/// Gabarit commun des écrans d'authentification : fond blanc, contenu
/// centré et limité en largeur (tablette, web), logo Partage+ en tête.
class AuthLayout extends StatelessWidget {
  const AuthLayout({
    super.key,
    required this.children,
    this.title,
    this.onBack,
    this.maxWidth = 440,
    this.showLogo = true,
  });

  final List<Widget> children;

  /// Largeur maximale du contenu (plus large pour un formulaire en grille).
  final double maxWidth;

  /// Affiche le logo complet au-dessus du contenu.
  final bool showLogo;

  /// Titre de la barre du haut (null : pas de barre, comme sur la maquette).
  final String? title;
  final VoidCallback? onBack;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.surface,
      appBar: title == null && onBack == null
          ? null
          : AppBar(
              title: title == null ? null : Text(title!),
              leading: onBack == null
                  ? null
                  : IconButton(
                      icon: const Icon(Icons.arrow_back),
                      tooltip: 'Retour',
                      onPressed: onBack,
                    ),
            ),
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
            child: ConstrainedBox(
              constraints: BoxConstraints(maxWidth: maxWidth),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (showLogo) ...[
                    const Center(child: BrandLogo.full(size: 120)),
                    const SizedBox(height: 24),
                  ],
                  ...children,
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Titre et sous-titre d'un écran (« Connexion / Accédez à votre compte »).
class AuthHeading extends StatelessWidget {
  const AuthHeading({super.key, required this.title, this.subtitle});

  final String title;
  final String? subtitle;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w700),
        ),
        if (subtitle != null) ...[
          const SizedBox(height: 4),
          Text(
            subtitle!,
            style: textTheme.bodyMedium?.copyWith(color: AppColors.textMuted),
          ),
        ],
      ],
    );
  }
}

/// Champ précédé de son libellé, comme sur la maquette.
/// Un champ obligatoire ([required]) est signalé par « * » après le libellé.
class LabeledField extends StatelessWidget {
  const LabeledField({
    super.key,
    required this.label,
    required this.child,
    this.required = false,
  });

  final String label;
  final Widget child;
  final bool required;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text.rich(
            TextSpan(
              text: label,
              children: [
                if (required)
                  const TextSpan(
                    text: ' *',
                    style: TextStyle(color: AppColors.danger),
                  ),
              ],
            ),
            style: Theme.of(context).textTheme.labelLarge?.copyWith(
              color: AppColors.text,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 6),
          child,
        ],
      ),
    );
  }
}

/// Champs en grille pour éviter le défilement : 4 colonnes au maximum sur
/// grand écran (web, tablette), 2 sur écran moyen, 1 sur téléphone.
/// Un enfant [FieldSpan] occupe plusieurs colonnes.
class FieldGrid extends StatelessWidget {
  const FieldGrid({super.key, required this.children});

  final List<Widget> children;

  static const _gap = 12.0;
  static const _minColumnWidth = 220.0;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        final fit = ((width + _gap) / (_minColumnWidth + _gap)).floor();
        // 3 colonnes laisseraient des rangées incomplètes : 4, 2 ou 1.
        final columns = fit >= 4 ? 4 : (fit >= 2 ? 2 : 1);
        final columnWidth = (width - _gap * (columns - 1)) / columns;
        double spanWidth(int span) {
          final n = span.clamp(1, columns);
          return columnWidth * n + _gap * (n - 1);
        }

        return Wrap(
          spacing: _gap,
          children: [
            for (final child in children)
              SizedBox(
                width: spanWidth(child is FieldSpan ? child.span : 1),
                child: child,
              ),
          ],
        );
      },
    );
  }
}

/// Élément de [FieldGrid] sur plusieurs colonnes ([full] : toute la largeur).
class FieldSpan extends StatelessWidget {
  const FieldSpan({super.key, required this.span, required this.child});

  const FieldSpan.full({super.key, required this.child}) : span = 4;

  final int span;
  final Widget child;

  @override
  Widget build(BuildContext context) => child;
}

/// Champ mot de passe avec boutons effacer (dès qu'il est rempli) et
/// afficher / masquer.
class PasswordField extends StatefulWidget {
  const PasswordField({
    super.key,
    required this.controller,
    this.hint = 'Votre mot de passe',
    this.label,
    this.helper,
    this.validator,
    this.textInputAction,
    this.onSubmitted,
    this.onChanged,
    this.autofillHints,
    this.fieldKey,
    this.focusNode,
  });

  final TextEditingController controller;
  final String hint;

  /// Libellé et aide dans le champ (quand il n'est pas dans un LabeledField).
  final String? label;
  final String? helper;
  final FormFieldValidator<String>? validator;
  final TextInputAction? textInputAction;
  final ValueChanged<String>? onSubmitted;
  final ValueChanged<String>? onChanged;
  final Iterable<String>? autofillHints;

  /// Pour revalider ce champ depuis un autre (confirmation du mot de passe).
  final GlobalKey<FormFieldState<String>>? fieldKey;
  final FocusNode? focusNode;

  @override
  State<PasswordField> createState() => _PasswordFieldState();
}

class _PasswordFieldState extends State<PasswordField> {
  var _obscure = true;
  FocusNode? _ownFocus;

  FocusNode get _focus => widget.focusNode ?? (_ownFocus ??= FocusNode());

  @override
  void dispose() {
    _ownFocus?.dispose();
    super.dispose();
  }

  /// Vide le champ et y replace le curseur ; prévient comme une saisie
  /// (revalidation de la confirmation…).
  void _clear() {
    widget.controller.clear();
    widget.onChanged?.call('');
    _focus.requestFocus();
  }

  @override
  Widget build(BuildContext context) {
    return TextFormField(
      key: widget.fieldKey,
      controller: widget.controller,
      focusNode: _focus,
      obscureText: _obscure,
      validator: widget.validator,
      textInputAction: widget.textInputAction,
      onChanged: widget.onChanged,
      onFieldSubmitted: widget.onSubmitted,
      autofillHints: widget.autofillHints,
      decoration: InputDecoration(
        hintText: widget.hint,
        labelText: widget.label,
        helperText: widget.helper,
        helperMaxLines: 2,
        suffixIcon: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListenableBuilder(
              listenable: widget.controller,
              builder: (context, _) => widget.controller.text.isEmpty
                  ? const SizedBox.shrink()
                  : IconButton(
                      icon: const Icon(Icons.clear),
                      tooltip: 'Effacer',
                      onPressed: _clear,
                    ),
            ),
            IconButton(
              icon: Icon(
                _obscure
                    ? Icons.visibility_outlined
                    : Icons.visibility_off_outlined,
              ),
              tooltip: _obscure ? 'Afficher' : 'Masquer',
              onPressed: () => setState(() => _obscure = !_obscure),
            ),
          ],
        ),
      ),
    );
  }
}

/// Confirmation du mot de passe : revérifiée dès que l'un des deux champs
/// change ; s'ils diffèrent, « Ressaisir le mot de passe » vide les deux
/// champs et replace le curseur dans [passwordFocus].
class ConfirmPasswordField extends StatefulWidget {
  const ConfirmPasswordField({
    super.key,
    required this.password,
    required this.controller,
    required this.passwordFocus,
    this.hint = 'Saisissez-le à nouveau',
    this.onSubmitted,
  });

  final TextEditingController password;
  final TextEditingController controller;
  final FocusNode passwordFocus;
  final String hint;
  final ValueChanged<String>? onSubmitted;

  @override
  State<ConfirmPasswordField> createState() => _ConfirmPasswordFieldState();
}

class _ConfirmPasswordFieldState extends State<ConfirmPasswordField> {
  final _field = GlobalKey<FormFieldState<String>>();
  var _mismatch = false;

  @override
  void initState() {
    super.initState();
    widget.password.addListener(_passwordChanged);
  }

  @override
  void dispose() {
    widget.password.removeListener(_passwordChanged);
    super.dispose();
  }

  /// Erreur déjà affichée : elle disparaît dès que les deux concordent.
  void _passwordChanged() {
    if (_field.currentState?.hasError ?? false) _field.currentState!.validate();
  }

  String? _validate(String? value) {
    final mismatch =
        value != null && value.isNotEmpty && value != widget.password.text;
    if (mismatch != _mismatch) {
      // Le validateur tourne pendant la construction : mise à jour après.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) setState(() => _mismatch = mismatch);
      });
    }
    if (value == null || value.isEmpty) return 'Confirmation obligatoire';
    if (mismatch) return 'Les mots de passe ne correspondent pas';
    return null;
  }

  void _retype() {
    // Pas de reset() : il remettrait la valeur saisie à la création du champ.
    widget.controller.clear();
    widget.password.clear();
    setState(() => _mismatch = false);
    widget.passwordFocus.requestFocus();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        PasswordField(
          fieldKey: _field,
          controller: widget.controller,
          hint: widget.hint,
          textInputAction: TextInputAction.done,
          onSubmitted: widget.onSubmitted,
          validator: _validate,
        ),
        if (_mismatch)
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: _retype,
              icon: const Icon(Icons.edit_outlined, size: 18),
              label: const Text('Ressaisir le mot de passe'),
            ),
          ),
      ],
    );
  }
}

/// Bouton principal qui affiche un indicateur pendant l'envoi.
class LoadingButton extends StatelessWidget {
  const LoadingButton({
    super.key,
    required this.label,
    required this.loading,
    required this.onPressed,
  });

  final String label;
  final bool loading;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return FilledButton(
      onPressed: loading ? null : onPressed,
      child: loading
          ? const SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: Colors.white,
              ),
            )
          : Text(label),
    );
  }
}

/// Lien « question + action » en bas d'écran (« Pas encore de compte ? S'inscrire »).
class AuthFooterLink extends StatelessWidget {
  const AuthFooterLink({
    super.key,
    required this.question,
    required this.action,
    required this.onTap,
  });

  final String question;
  final String action;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      alignment: WrapAlignment.center,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        Text(question, style: const TextStyle(color: AppColors.textMuted)),
        TextButton(onPressed: onTap, child: Text(action)),
      ],
    );
  }
}

void showMessage(BuildContext context, String message, {bool error = false}) {
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: error ? AppColors.danger : null,
      ),
    );
}

// ---------- Validation des champs ----------

final _emailPattern = RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$');

String? validateEmail(String? value) {
  final email = value?.trim() ?? '';
  if (email.isEmpty) return 'Adresse e-mail obligatoire';
  if (!_emailPattern.hasMatch(email)) return 'Adresse e-mail invalide';
  return null;
}

String? validatePassword(String? value) {
  final password = value ?? '';
  if (password.isEmpty) return 'Mot de passe obligatoire';
  if (password.length < 8) return '8 caractères minimum';
  if (!password.contains(RegExp(r'[0-9]'))) return 'Au moins un chiffre';
  if (!password.contains(RegExp(r'[A-Za-z]'))) return 'Au moins une lettre';
  return null;
}

String? Function(String?) requiredField(String message) =>
    (value) => (value == null || value.trim().isEmpty) ? message : null;
