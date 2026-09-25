import 'package:flutter/material.dart';

import 'tokens.dart';

/// HR-zone background palette (design addendum A1, plan §18.1). Zones are
/// shares of the resolved max HR: Z1 < 60 %, Z2 60–70, Z3 70–80, Z4 80–90,
/// Z5 ≥ 90; zone 0 = no strap / no signal. Every background keeps Bone
/// ≥ 10.4:1 and sits at ≤ 3.4 % relative luminance (OLED draw near black).
/// The luminance ramp is deliberately not monotone (Z3 brightest, Z1
/// darkest) because deuteranopia confuses Z2/Z3/Z4 at these levels, which is
/// why the label and gauge are mandatory and colour is reinforcement only.
abstract final class HrZones {
  static const int count = 5;

  static const List<Color> backgrounds = [
    NightSession.bgBase, // 0: today's base
    Color(0xFF0E2140), // 1: deep navy
    Color(0xFF0C3322), // 2: deep green
    Color(0xFF3A3410), // 3: olive
    Color(0xFF4A2208), // 4: burnt orange
    Color(0xFF4E0E18), // 5: deep red
  ];

  static const List<String> words = [
    '',
    'EASY',
    'STEADY',
    'TEMPO',
    'HARD',
    'MAX',
  ];

  /// Secondary labels on a zone background. The addendum says Bone at 70 %
  /// (7.0:1 or better on every zone); measured with WCAG relative luminance
  /// that is 6.4:1 on Z2 and 6.0:1 on Z3, so this is Bone at 80 %, the
  /// lowest alpha that clears 7:1 on all five (7.3:1 on Z3). The golden
  /// test's contrast audit pins it.
  static const Color secondaryOnZone = Color(0xCCEDEAE3);

  /// Empty gauge segment.
  static const Color gaugeEmpty = Color(0x33FFFFFF);

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
