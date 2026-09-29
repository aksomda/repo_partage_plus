import 'package:flutter/material.dart';

/// Couleurs de la charte Partage+.
abstract final class AppColors {
  /// Vert foncé : boutons principaux, barre latérale admin.
  static const primary = Color(0xFF1B7A3A);

  /// Vert vif : pictogrammes, puces actives, feuille du logo.
  static const leaf = Color(0xFF4CAF50);

  /// Orange : le « + » du logo, prix, pictogrammes secondaires.
  static const accent = Color(0xFFF39200);

  /// Rouge : favoris, rappels d'expiration, comptes désactivés.
  static const danger = Color(0xFFE53935);

  static const background = Color(0xFFF6F8F6);
  static const surface = Colors.white;
  static const border = Color(0xFFE3E8E4);
  static const text = Color(0xFF1D2B22);
  static const textMuted = Color(0xFF6B7A70);

  /// Fond vert pâle des pastilles d'icônes et des chips.
  static const primarySoft = Color(0xFFE6F3EA);

  /// Fond orange pâle des pastilles secondaires.
  static const accentSoft = Color(0xFFFDEFD9);
}

abstract final class AppTheme {
  static const radius = 12.0;

  static ThemeData light() {
    final colorScheme =
        ColorScheme.fromSeed(
          seedColor: AppColors.primary,
          brightness: Brightness.light,
        ).copyWith(
          primary: AppColors.primary,
          onPrimary: Colors.white,
          primaryContainer: AppColors.primarySoft,
          onPrimaryContainer: AppColors.primary,
          secondary: AppColors.accent,
          onSecondary: Colors.white,
          secondaryContainer: AppColors.accentSoft,
          onSecondaryContainer: const Color(0xFF7A4A00),
          error: AppColors.danger,
          surface: AppColors.surface,
          onSurface: AppColors.text,
          onSurfaceVariant: AppColors.textMuted,
          outline: AppColors.border,
          outlineVariant: AppColors.border,
        );

    final shape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(radius),
    );
    const buttonPadding = EdgeInsets.symmetric(horizontal: 24, vertical: 14);
    const buttonText = TextStyle(fontSize: 15, fontWeight: FontWeight.w600);

    OutlineInputBorder inputBorder(Color color, [double width = 1]) =>
        OutlineInputBorder(
          borderRadius: BorderRadius.circular(radius),
          borderSide: BorderSide(color: color, width: width),
        );

    return ThemeData(
      colorScheme: colorScheme,
      scaffoldBackgroundColor: AppColors.background,
      appBarTheme: const AppBarTheme(
        backgroundColor: AppColors.surface,
        foregroundColor: AppColors.text,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0.5,
        centerTitle: false,
        titleTextStyle: TextStyle(
          color: AppColors.text,
          fontSize: 18,
          fontWeight: FontWeight.w700,
        ),
      ),
      cardTheme: CardThemeData(
        color: AppColors.surface,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(radius),
          side: const BorderSide(color: AppColors.border),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: AppColors.primary,
          foregroundColor: Colors.white,
          padding: buttonPadding,
          textStyle: buttonText,
          shape: shape,
        ),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: AppColors.primary,
          foregroundColor: Colors.white,
          elevation: 0,
          padding: buttonPadding,
          textStyle: buttonText,
          shape: shape,
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: AppColors.primary,
          side: const BorderSide(color: AppColors.primary),
          padding: buttonPadding,
          textStyle: buttonText,
          shape: shape,
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: AppColors.primary,
          textStyle: const TextStyle(fontWeight: FontWeight.w600),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: AppColors.surface,
        hintStyle: const TextStyle(color: AppColors.textMuted),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 16,
          vertical: 14,
        ),
        border: inputBorder(AppColors.border),
        enabledBorder: inputBorder(AppColors.border),
        focusedBorder: inputBorder(AppColors.primary, 1.5),
        errorBorder: inputBorder(AppColors.danger),
      ),
      chipTheme: ChipThemeData(
        backgroundColor: AppColors.surface,
        selectedColor: AppColors.primary,
        secondarySelectedColor: AppColors.primary,
        labelStyle: const TextStyle(color: AppColors.text, fontSize: 13),
        secondaryLabelStyle: const TextStyle(color: Colors.white),
        side: const BorderSide(color: AppColors.border),
        shape: const StadiumBorder(),
        showCheckmark: false,
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: AppColors.surface,
        surfaceTintColor: Colors.transparent,
        indicatorColor: AppColors.primarySoft,
        labelTextStyle: WidgetStateProperty.resolveWith(
          (states) => TextStyle(
            fontSize: 11,
            fontWeight: states.contains(WidgetState.selected)
                ? FontWeight.w600
                : FontWeight.w400,
            color: states.contains(WidgetState.selected)
                ? AppColors.primary
                : AppColors.textMuted,
          ),
        ),
      ),
      floatingActionButtonTheme: const FloatingActionButtonThemeData(
        backgroundColor: AppColors.leaf,
        foregroundColor: Colors.white,
        shape: CircleBorder(),
      ),
      switchTheme: SwitchThemeData(
        thumbColor: const WidgetStatePropertyAll(Colors.white),
        trackColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected)
              ? AppColors.primary
              : AppColors.border,
        ),
        trackOutlineColor: const WidgetStatePropertyAll(Colors.transparent),
      ),
      sliderTheme: const SliderThemeData(
        activeTrackColor: AppColors.primary,
        inactiveTrackColor: AppColors.border,
        thumbColor: AppColors.primary,
      ),
      drawerTheme: const DrawerThemeData(
        backgroundColor: AppColors.surface,
        surfaceTintColor: Colors.transparent,
      ),
      listTileTheme: const ListTileThemeData(
        iconColor: AppColors.text,
        contentPadding: EdgeInsets.symmetric(horizontal: 16),
      ),
      dividerTheme: const DividerThemeData(
        color: AppColors.border,
        thickness: 1,
        space: 1,
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        backgroundColor: AppColors.text,
        shape: shape,
      ),
    );
  }
}
