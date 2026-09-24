import 'package:flutter/material.dart';

/// Type scale (design brief §2.2 / §5). Barlow Condensed for display, Archivo for UI.
/// No Inter, no Roboto. Display never below 28 px. Numbers always tabular.
abstract final class RunSoloType {
  static const String display = 'Barlow Condensed';
  static const String ui = 'Archivo';

  static const List<FontFeature> tabular = [FontFeature.tabularFigures()];

  static TextStyle _display(double size, FontWeight weight) => TextStyle(
        fontFamily: display,
        fontSize: size,
        fontWeight: weight,
        height: 1.0,
        letterSpacing: size * 0.01,
        fontFeatures: tabular,
      );

  static TextStyle _ui(double size, FontWeight weight) => TextStyle(
        fontFamily: ui,
        fontSize: size,
        fontWeight: weight,
        height: 1.35,
        fontFeatures: tabular,
      );

  static final TextStyle display96 = _display(96, FontWeight.w700);
  static final TextStyle display64 = _display(64, FontWeight.w700);
  static final TextStyle display44 = _display(44, FontWeight.w600);
  static final TextStyle title28 = _display(28, FontWeight.w600);
  static final TextStyle timer120 = _display(120, FontWeight.w600);
  static final TextStyle body17 = _ui(17, FontWeight.w400);
  static final TextStyle body15 = _ui(15, FontWeight.w400);
  static final TextStyle label13 = _ui(13, FontWeight.w500);
  static final TextStyle micro11 = TextStyle(
    fontFamily: ui,
    fontSize: 11,
    fontWeight: FontWeight.w500,
    letterSpacing: 11 * 0.08,
    height: 1.2,
  );

  static TextTheme textTheme(Color ink, Color inkSecondary) => TextTheme(
        displayLarge: display96.copyWith(color: ink),
        displayMedium: display64.copyWith(color: ink),
        displaySmall: display44.copyWith(color: ink),
        headlineMedium: title28.copyWith(color: ink),
        bodyLarge: body17.copyWith(color: ink),
        bodyMedium: body15.copyWith(color: ink),
        labelLarge: label13.copyWith(color: ink),
        labelSmall: micro11.copyWith(color: inkSecondary),
      );
}
