import 'package:flutter/material.dart';

/// Type scale (design brief §2.2 / §5, brand build 7-Oct-2026). Saira Extra
/// Condensed for display, Schibsted Grotesk for UI. No Inter, no Roboto.
/// Display never below 28 px. Numbers always tabular.
///
/// Saira Extra Condensed is narrower than the Barlow Condensed it replaced
/// (digit advance 0.37 em vs 0.42) with a slightly lower cap height (0.688 vs
/// 0.700), so every display size is scaled by [_displayScale] to land at or
/// above the old cap height. Nothing got smaller. Saira has no 600, so the
/// old 600 -> 700 and 700 -> 800.
abstract final class RunSoloType {
  static const String display = 'Saira Extra Condensed';
  static const String ui = 'Schibsted Grotesk';

  static const List<FontFeature> tabular = [FontFeature.tabularFigures()];

  static const double _displayScale = 1.05;

  /// An in-run number's explicit size, scaled for Saira the same way: the
  /// readability rule is that no in-run number gets shorter, and a hand-set
  /// `fontSize` skips [_display]'s scale. Pass the old Barlow size.
  static double runSize(double base) => (base * _displayScale).roundToDouble();

  /// A display style at the old Barlow size [base], scaled for Saira.
  static TextStyle _display(double base, FontWeight weight) {
    final size = (base * _displayScale).roundToDouble();
    return TextStyle(
      fontFamily: display,
      fontSize: size,
      fontWeight: weight,
      height: 1.0,
      letterSpacing: size * 0.01,
      fontFeatures: tabular,
    );
  }

  static TextStyle _ui(double size, FontWeight weight) => TextStyle(
    fontFamily: ui,
    fontSize: size,
    fontWeight: weight,
    height: 1.35,
    // No tnum here: Schibsted's tnum also widens , . : and %, which opens a
    // gap before punctuation in prose. Number columns pass [tabular] explicitly.
  );

  static final TextStyle display96 = _display(96, FontWeight.w800);

  /// Home's plain-words statement ("7 in 10"), Saira 800 at ~56 sp.
  static final TextStyle statement56 = _display(54, FontWeight.w800);
  static final TextStyle display64 = _display(64, FontWeight.w800);
  static final TextStyle display44 = _display(44, FontWeight.w700);
  static final TextStyle title28 = _display(28, FontWeight.w700);

  /// Page-level headline (Start's question, Home's progress line).
  static final TextStyle pageHeadline = title28;

  /// The app bar title on every screen.
  static final TextStyle appBarTitle = heading26;
  static final TextStyle heading26 = _display(26, FontWeight.w700);
  static final TextStyle heading19 = _display(19, FontWeight.w800);
  static final TextStyle timer120 = _display(120, FontWeight.w700);
  static final TextStyle body17 = _ui(17, FontWeight.w400);
  static final TextStyle body15 = _ui(15, FontWeight.w400);
  static final TextStyle label13 = _ui(13, FontWeight.w500);

  /// The smallest text on the record screen (S1, design review 11-Oct): a
  /// caption or note is never under 16 sp, however short the phone.
  static final TextStyle runCaption = _ui(16, FontWeight.w600);
  static final TextStyle runNote = _ui(16, FontWeight.w400);
  static final TextStyle micro11 = TextStyle(
    fontFamily: ui,
    fontSize: 11,
    fontWeight: FontWeight.w500,
    letterSpacing: 11 * 0.08,
    height: 1.2,
  );

  /// A metric label on the run screen (CLIMB, HEART RATE, TARGET...): read at
  /// arm's length mid-run (founder, 10-Oct trail run), so well above
  /// [micro11]. Still far smaller than the 36 sp numbers it sits over.
  static final TextStyle runLabel = TextStyle(
    fontFamily: ui,
    fontSize: 17,
    fontWeight: FontWeight.w600,
    letterSpacing: 17 * 0.05,
    height: 1.15,
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
