import 'package:flutter/material.dart';

import 'tokens.dart';

/// HR-zone palette (design addendum A1, plan §18.1; O5 redesign 6-Oct).
/// Zones are shares of the resolved max HR: Z1 < 60 %, Z2 60–70, Z3 70–80,
/// Z4 80–90, Z5 ≥ 90; zone 0 = no strap / no signal. The record screen stays
/// near black (the app background) in every zone, for the best number
/// contrast in sun; the zone shows as a bold band across the top and a faint
/// edge glow, painted in the SAME five hues as the post-run time-in-zone
/// chart ([distributionDark]). The old full-screen fills read muddy (olive,
/// brown) and brown behind Bone lost contrast outdoors. Colour is still
/// reinforcement only: the label and gauge stay mandatory.
abstract final class HrZones {
  static const int count = 5;

  /// The record screen's ground, one per zone. All the same near black since
  /// the O5 redesign (kept as a list so callers index by zone unchanged).
  /// Before: 0 #0A0B0D, 1 #0E2140, 2 #0C3322, 3 #3F2A05, 4 #4C1D04, 5 #4E0E18.
  static const List<Color> backgrounds = [
    NightSession.bgBase,
    NightSession.bgBase,
    NightSession.bgBase,
    NightSession.bgBase,
    NightSession.bgBase,
    NightSession.bgBase,
  ];

  /// The zone band / edge glow colour on the record screen: the time-in-zone
  /// hues. Zone 0 (no HR) has no band, so it is the ground itself.
  static Color band(int zone) =>
      zone <= 0 ? NightSession.bgBase : distributionDark[zone.clamp(1, count)];

  static const List<String> words = [
    '',
    'EASY',
    'STEADY',
    'TEMPO',
    'HARD',
    'MAX',
  ];

  /// Zone hues for post-run distributions (run detail "Time in zone"). The
  /// in-run backgrounds above stay near black; these are the brighter hues,
  /// used only for bars and swatches, never behind text. Each is >= 5.5:1
  /// against the dark surfaces and >= 4.0:1 against every light surface, so
  /// both sets clear the 3:1 graphics floor. Index 0 is unused. Rows always
  /// carry the zone name, so colour is never the only cue.
  static const List<Color> distributionDark = [
    NightSession.semNoise,
    Color(0xFF4D9BFF), // Z1 blue
    Color(0xFF2FD07A), // Z2 green
    Color(0xFFFFBE2E), // Z3 amber
    Color(0xFFFF7A2E), // Z4 orange
    Color(0xFFFF4D5E), // Z5 red
  ];

  static const List<Color> distributionLight = [
    NightSessionLight.semNoise,
    Color(0xFF1A63C7),
    Color(0xFF12803F),
    Color(0xFF9A6200),
    Color(0xFFBE3E08),
    Color(0xFFC41230),
  ];

  static Color distribution(int zone, Brightness brightness) =>
      (brightness == Brightness.dark
      ? distributionDark
      : distributionLight)[zone.clamp(0, count)];

  /// Secondary labels on a zone background. The addendum says Bone at 70 %
  /// (7.0:1 or better on every zone); measured with WCAG relative luminance
  /// that is 6.4:1 on Z2 and 6.0:1 on Z3, so this is Bone at 80 %, the
  /// lowest alpha that clears 7:1 on all five (7.3:1 on Z3). The golden
  /// test's contrast audit pins it.
  static const Color secondaryOnZone = Color(0xCCEDEAE3);

  /// Empty gauge segment.
  static const Color gaugeEmpty = Color(0x33FFFFFF);

  /// Title-case zone name for rows ("Tempo").
  static String name(int zone) {
    final w = words[zone.clamp(1, count)];
    return '${w[0]}${w.substring(1).toLowerCase()}';
  }

  static Color background(int zone) => backgrounds[zone.clamp(0, count)];

  /// "ZONE 4 · HARD"; zone 0 reads as the strap state instead.
  static String label(int zone, {required bool paired}) {
    if (zone <= 0) return paired ? 'RECONNECTING' : 'NO STRAP';
    return 'ZONE $zone · ${words[zone]}';
  }

  /// Zone for an HR share of max, without hysteresis (display-only helper
  /// for run detail; the live screen uses the engine tracker).
  static int zoneForFraction(double fraction) {
    if (fraction < 0.6) return 1;
    if (fraction < 0.7) return 2;
    if (fraction < 0.8) return 3;
    if (fraction < 0.9) return 4;
    return 5;
  }
}
