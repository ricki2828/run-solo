import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'tokens.dart';
import 'typography.dart';

export 'motion.dart';
export 'run_label.dart';
export 'tokens.dart';
export 'typography.dart';

/// Everyday screens are light; the recording screen and the share card ask
/// for [Brightness.dark] explicitly.
///
/// ThemeData mapping from the design brief §5: surface = bg.base,
/// surfaceContainer = bg.raised, primary = ink.primary, tertiary = accent.arc,
/// error = sem.danger. No shadow elevation, no default ripple colour.
ThemeData runSoloTheme({Brightness brightness = Brightness.light}) {
  final t = brightness == Brightness.dark
      ? RunSoloTokens.dark
      : RunSoloTokens.light;
  // Primary button: ink fill, white text on light; Bone fill, dark text on dark.
  final onButton = brightness == Brightness.light ? t.bgRaised : t.bgBase;
  final scheme = ColorScheme(
    brightness: brightness,
    primary: t.inkPrimary,
    onPrimary: onButton,
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
      surfaceTintColor: Colors.transparent,
      systemOverlayStyle: brightness == Brightness.light
          ? SystemUiOverlayStyle.dark
          : SystemUiOverlayStyle.light,
    ),
    // Material's default unselected radio is onSurface at 60 %, which is
    // 2.6:1 on the light ground. Use the secondary ink instead.
    radioTheme: RadioThemeData(
      fillColor: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.selected)
            ? t.inkPrimary
            : t.inkSecondary,
      ),
    ),
    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.resolveWith(
        (states) =>
            states.contains(WidgetState.selected) ? onButton : t.inkSecondary,
      ),
      trackColor: WidgetStateProperty.resolveWith(
        (states) =>
            states.contains(WidgetState.selected) ? t.inkPrimary : t.bgSunken,
      ),
      trackOutlineColor: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.selected)
            ? t.inkPrimary
            : t.inkSecondary,
      ),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: t.bgRaised,
      surfaceTintColor: Colors.transparent,
    ),
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: t.bgRaised,
      surfaceTintColor: Colors.transparent,
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
        foregroundColor: onButton,
        minimumSize: const Size.fromHeight(64),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(Radii.button),
        ),
        textStyle: RunSoloType.title28,
      ),
    ),
  );
}
