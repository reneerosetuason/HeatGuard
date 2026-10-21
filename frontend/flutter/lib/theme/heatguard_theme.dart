import 'package:flutter/material.dart';

abstract final class HeatGuardColors {
  static const background = Color(0xFFF6F7F3);
  static const ink = Color(0xFF203C38);
  static const muted = Color(0xFF667C76);
  static const teal = Color(0xFF216D63);
  static const deepTeal = Color(0xFF163F3B);
  static const mint = Color(0xFFE8F1EB);
  static const border = Color(0xFFE2E8E1);
  static const sand = Color(0xFFF4EAD7);
  static const gold = Color(0xFFE7C17C);

  static Color risk(String value) {
    final label = value.toLowerCase().replaceAll('_', ' ');
    if (label.contains('extreme danger')) return const Color(0xFF9A3658);
    if (label.contains('danger')) return const Color(0xFFB14436);
    if (label.contains('extreme caution') || label.contains('very high')) {
      return const Color(0xFFA65B28);
    }
    if (label.contains('caution') || label.contains('moderate')) {
      return const Color(0xFF88631F);
    }
    if (label.contains('low') || label == 'safe') return teal;
    return muted;
  }
}

ThemeData buildHeatGuardTheme() {
  final scheme = ColorScheme.fromSeed(
    seedColor: HeatGuardColors.teal,
    primary: HeatGuardColors.teal,
    onPrimary: Colors.white,
    secondary: const Color(0xFF8D6D34),
    surface: Colors.white,
    onSurface: HeatGuardColors.ink,
    outline: HeatGuardColors.muted,
    outlineVariant: HeatGuardColors.border,
  );
  final base = ThemeData(useMaterial3: true, colorScheme: scheme);
  final rounded = RoundedRectangleBorder(
    borderRadius: BorderRadius.circular(18),
  );
  return base.copyWith(
    scaffoldBackgroundColor: HeatGuardColors.background,
    textTheme: base.textTheme
        .apply(
          bodyColor: HeatGuardColors.ink,
          displayColor: HeatGuardColors.ink,
        )
        .copyWith(
          headlineMedium: const TextStyle(
            fontSize: 30,
            height: 1.18,
            fontWeight: FontWeight.w700,
            letterSpacing: -1.1,
            color: HeatGuardColors.ink,
          ),
          titleLarge: const TextStyle(
            fontSize: 21,
            fontWeight: FontWeight.w700,
            letterSpacing: -0.5,
            color: HeatGuardColors.ink,
          ),
          titleMedium: const TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w700,
            letterSpacing: -0.25,
            color: HeatGuardColors.ink,
          ),
          bodyMedium: const TextStyle(
            fontSize: 14,
            height: 1.5,
            color: HeatGuardColors.muted,
          ),
        ),
    appBarTheme: const AppBarTheme(
      backgroundColor: HeatGuardColors.background,
      foregroundColor: HeatGuardColors.ink,
      surfaceTintColor: Colors.transparent,
      centerTitle: false,
      elevation: 0,
      scrolledUnderElevation: 0,
      toolbarHeight: 76,
    ),
    cardTheme: CardThemeData(
      color: Colors.white,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(24),
        side: const BorderSide(color: HeatGuardColors.border),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: Colors.white,
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 17),
      labelStyle: const TextStyle(color: HeatGuardColors.muted),
      floatingLabelStyle: const TextStyle(color: HeatGuardColors.teal),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(16),
        borderSide: const BorderSide(color: HeatGuardColors.border),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(16),
        borderSide: const BorderSide(color: HeatGuardColors.border),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(16),
        borderSide: const BorderSide(color: HeatGuardColors.teal, width: 1.5),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        minimumSize: const Size(48, 50),
        shape: rounded,
        textStyle: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        minimumSize: const Size(48, 48),
        shape: rounded,
        side: const BorderSide(color: HeatGuardColors.border),
        textStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
      ),
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: Colors.white,
      surfaceTintColor: Colors.transparent,
      indicatorColor: HeatGuardColors.mint,
      height: 76,
      labelTextStyle: WidgetStateProperty.resolveWith(
        (states) => TextStyle(
          fontSize: 11,
          fontWeight: states.contains(WidgetState.selected)
              ? FontWeight.w700
              : FontWeight.w500,
          color: states.contains(WidgetState.selected)
              ? HeatGuardColors.teal
              : HeatGuardColors.muted,
        ),
      ),
      iconTheme: WidgetStateProperty.resolveWith(
        (states) => IconThemeData(
          size: 23,
          color: states.contains(WidgetState.selected)
              ? HeatGuardColors.teal
              : HeatGuardColors.muted,
        ),
      ),
    ),
    tabBarTheme: const TabBarThemeData(
      labelColor: HeatGuardColors.teal,
      unselectedLabelColor: HeatGuardColors.muted,
      indicatorColor: HeatGuardColors.teal,
      dividerColor: HeatGuardColors.border,
    ),
    bottomSheetTheme: const BottomSheetThemeData(
      backgroundColor: HeatGuardColors.background,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      clipBehavior: Clip.antiAlias,
    ),
    dividerTheme: const DividerThemeData(color: HeatGuardColors.border),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      backgroundColor: HeatGuardColors.deepTeal,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
    ),
  );
}
