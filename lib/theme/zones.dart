import 'package:flutter/material.dart';

import 'tokens.dart';

/// HR-zone floods for the run screen (design addendum A1, plan §18.1; Full
/// Instrument palette, 7-Oct-2026). Zones are shares of the resolved max HR:
/// Z1 < 60 %, Z2 60–70, Z3 70–80, Z4 80–90, Z5 ≥ 90; zone 0 = no strap / no
/// signal (the near-black base). The fills are clean and flat, the deep
/// versions of the chart ramp (blue, green, amber, orange, red), and keep
/// Bone numbers at 7:1 or better on every one (Z1 8.8, Z2 7.1, Z3 7.1, Z4
/// 7.1, Z5 8.8). Colour is reinforcement only: the label, the gauge and the
/// right-edge ladder stay.
abstract final class HrZones {
  static const int count = 5;

  /// Brief values were Z2 #17603A, Z3 #7A5A08, Z4 #8A3410; those give Bone
  /// 6.3, 5.3 and 6.8:1, so each is darkened just enough to reach 7.1:1.
  static const List<Color> backgrounds = [
    NightSession.bgBase, // 0: no HR
    Color(0xFF1C3F6E), // 1: blue
    Color(0xFF155835), // 2: green (brief #17603A)
    Color(0xFF624806), // 3: amber (brief #7A5A08)
    Color(0xFF863210), // 4: orange (brief #8A3410)
    Color(0xFF7D1222), // 5: red
  ];

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

  /// The brand zone ramp for fills on light screens (bars, swatches). Flat,
  /// clear colour; fills are not text, so no 4.5:1 rule. Use
  /// [distributionLightText] for zone-coloured text.
  static const List<Color> distributionLight = [
    NightSessionLight.semNoise,
    Color(0xFF2F6DB5),
    Color(0xFF2E9E5B),
    Color(0xFFD9A21B),
    Color(0xFFE86A1C),
    Color(0xFFD6283B),
  ];

  /// Darker zone hues for text on the light ground (>= 4.0:1 on every light
  /// surface).
  static const List<Color> distributionLightText = [
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

  /// [distribution] for zone-coloured text.
  static Color text(int zone, Brightness brightness) =>
      (brightness == Brightness.dark
      ? distributionDark
      : distributionLightText)[zone.clamp(0, count)];

  /// Secondary labels on a zone flood: Bone at 90 %, 6.0:1 or better on all
  /// five (the old 7:1 at 80 % is not reachable on the brighter floods short
  /// of full Bone). Numbers stay full Bone at 7:1; the contrast audit pins
  /// both.
  static const Color secondaryOnZone = Color(0xE6EDEAE3);

  /// Empty gauge segment.
  static const Color gaugeEmpty = Color(0x33FFFFFF);

  /// Title-case zone name for rows ("Tempo").
  static String name(int zone) {
    final w = words[zone.clamp(1, count)];
    return '${w[0]}${w.substring(1).toLowerCase()}';
  }

  static Color background(int zone) => backgrounds[zone.clamp(0, count)];

  /// WCAG contrast ratio of two opaque colours.
  static double contrast(Color a, Color b) {
    final la = a.computeLuminance(), lb = b.computeLuminance();
    final hi = la > lb ? la : lb, lo = la > lb ? lb : la;
    return (hi + 0.05) / (lo + 0.05);
  }

  /// [colour] as text on the zone's fill when it reads (>= 4.5:1), else
  /// [fallback] (Bone). Used for the zone label and the rep / recovery phase
  /// title, which keep their own hue only where the fill lets them.
  static Color legibleOn(int zone, Color colour, Color fallback) =>
      contrast(colour, background(zone)) >= 4.5 ? colour : fallback;

  /// The zone's own hue (the time-in-zone chart's) as a label on its fill,
  /// Bone where that hue does not read on it.
  static Color labelOn(int zone, Color fallback) =>
      zone <= 0 ? fallback : legibleOn(zone, distributionDark[zone], fallback);

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
