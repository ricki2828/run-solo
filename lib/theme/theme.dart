import 'package:flutter/material.dart';

import 'tokens.dart';
import 'typography.dart';

export 'motion.dart';
export 'tokens.dart';
export 'typography.dart';

/// ThemeData mapping from the design brief §5: surface = bg.base,
/// surfaceContainer = bg.raised, primary = ink.primary, tertiary = accent.arc,
/// error = sem.danger. No shadow elevation, no default ripple colour.
ThemeData runSoloTheme({Brightness brightness = Brightness.dark}) {
  final t = brightness == Brightness.dark
      ? RunSoloTokens.dark
      : RunSoloTokens.light;
  final scheme = ColorScheme(
    brightness: brightness,
    primary: t.inkPrimary,
    onPrimary: t.bgBase,
    secondary: t.inkSecondary,
    onSecondary: t.bgBase,
    tertiary: t.accentArc,
    onTertiary: t.accentArcInk,
    error: t.semDanger,
    onError: t.inkPrimary,
    surface: t.bgBase,
    onSurface: t.inkPrimary,
    surfaceContainer: t.bgRaised,
    surfaceContainerLowest: t.bgSunken,
    onSurfaceVariant: t.inkSecondary,
    outline: t.inkMuted,
    outlineVariant: t.lineHair,
  );
  return ThemeData(
    useMaterial3: true,
    brightness: brightness,
    colorScheme: scheme,
    scaffoldBackgroundColor: t.bgBase,
    canvasColor: t.bgBase,
    splashFactory: NoSplash.splashFactory,
    fontFamily: RunSoloType.ui,
    textTheme: RunSoloType.textTheme(t.inkPrimary, t.inkSecondary),
    dividerColor: t.lineHair,
    extensions: [t],
    appBarTheme: AppBarTheme(
      backgroundColor: t.bgBase,
      foregroundColor: t.inkPrimary,
      elevation: 0,
      scrolledUnderElevation: 0,
    ),
    cardTheme: CardThemeData(
      color: t.bgRaised,
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(Radii.card),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: t.inkPrimary,
        foregroundColor: t.bgBase,
        minimumSize: const Size.fromHeight(64),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(Radii.button),
        ),
        textStyle: RunSoloType.title28,
      ),
    ),
  );
}
