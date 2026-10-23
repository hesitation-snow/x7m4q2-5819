import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'app_motion.dart';

/// Shared Material 3 defaults. Reader paper and ink remain reader-owned.
abstract final class AppTheme {
  static ThemeData build(Brightness brightness) {
    final scheme = ColorScheme.fromSeed(
      seedColor: const Color(0xFF5C6BC0),
      brightness: brightness,
    );
    final dark = brightness == Brightness.dark;
    final shape =
        RoundedRectangleBorder(borderRadius: BorderRadius.circular(16));
    final base = ThemeData(useMaterial3: true, colorScheme: scheme);
    return base.copyWith(
      pageTransitionsTheme: AppMotion.disabled
          ? AppMotion.noPageTransitions
          : const PageTransitionsTheme(),
      splashFactory: AppMotion.disabled
          ? NoSplash.splashFactory
          : InkSparkle.splashFactory,
      scaffoldBackgroundColor: scheme.surface,
      appBarTheme: AppBarTheme(
        centerTitle: true,
        elevation: 0,
        scrolledUnderElevation: 0,
        backgroundColor: scheme.surface,
        foregroundColor: scheme.onSurface,
        titleTextStyle: base.textTheme.titleMedium?.copyWith(
          color: scheme.onSurface,
          fontWeight: FontWeight.w600,
        ),
        systemOverlayStyle: SystemUiOverlayStyle(
          statusBarColor: Colors.transparent,
          statusBarIconBrightness: dark ? Brightness.light : Brightness.dark,
          statusBarBrightness: brightness,
        ),
      ),
      cardTheme: CardThemeData(
        elevation: 0,
        margin: EdgeInsets.zero,
        color: scheme.surfaceContainerLow,
        surfaceTintColor: Colors.transparent,
        shape: shape,
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: scheme.surfaceContainerHighest,
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(16),
            borderSide: BorderSide.none),
        enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(16),
            borderSide: BorderSide.none),
        focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(16),
            borderSide: BorderSide(color: scheme.primary, width: 2)),
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: scheme.surfaceContainer,
        indicatorColor: scheme.secondaryContainer,
        height: 64,
        labelTextStyle: WidgetStateProperty.resolveWith(
            (states) => TextStyle(
                  fontSize: 11,
                  color: states.contains(WidgetState.selected)
                      ? scheme.onSurface
                      : scheme.onSurfaceVariant,
                  fontWeight: states.contains(WidgetState.selected)
                      ? FontWeight.w600
                      : FontWeight.normal,
                )),
      ),
      dividerTheme: DividerThemeData(
          color: scheme.outlineVariant, thickness: .5, space: 1),
      listTileTheme: ListTileThemeData(
        iconColor: scheme.onSurfaceVariant,
        textColor: scheme.onSurface,
        // Transparent rows allow grouped lists to share one surface.
        tileColor: Colors.transparent,
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
        shape: shape,
      ),
      filledButtonTheme: FilledButtonThemeData(
          style: FilledButton.styleFrom(
        minimumSize: const Size(64, 40),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      )),
      outlinedButtonTheme: OutlinedButtonThemeData(
          style: OutlinedButton.styleFrom(
        minimumSize: const Size(64, 40),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      )),
      textButtonTheme: TextButtonThemeData(
          style: TextButton.styleFrom(minimumSize: const Size(40, 40))),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: scheme.surfaceContainerLow,
        surfaceTintColor: Colors.transparent,
        shape: const RoundedRectangleBorder(
            borderRadius: BorderRadius.vertical(top: Radius.circular(28))),
        clipBehavior: Clip.antiAlias,
      ),
      popupMenuTheme: PopupMenuThemeData(
        color: scheme.surfaceContainer,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      ),
      chipTheme: base.chipTheme.copyWith(
        side: BorderSide(color: scheme.outlineVariant.withValues(alpha: 0.5)),
        selectedColor: scheme.secondaryContainer,
        labelStyle: TextStyle(fontSize: 12, color: scheme.onSurface),
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 0),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      ),
    );
  }
}
