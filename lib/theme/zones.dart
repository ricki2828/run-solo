import 'package:flutter/material.dart';

import 'tokens.dart';

/// HR-zone floods for the run screen (design addendum A1, plan §18.1; Full
/// Instrument palette, 7-Oct-2026). Zones are shares of the resolved max HR:
/// Z1 < 60 %, Z2 60–70, Z3 70–80, Z4 80–90, Z5 ≥ 90; zone 0 = no strap / no
/// signal (the flood takes the run type's colour, see [RunFlood]). The fills
/// are clean and flat. Z1, Z2 and Z5 are deep (blue, green, red) and carry
/// Bone foreground at 7:1 or better (Z1 8.8, Z2 7.1, Z5 8.8). Z3 and Z4 are
/// bright true yellow and orange (Ricki, 11-Oct, D1) and carry INK (near-
/// black) foreground instead, 12.9 and 7.6:1. Colour is reinforcement only:
/// the label, the gauge and the right-edge ladder stay.
abstract final class HrZones {
  static const int count = 5;

  /// Z2 is darkened from the brief's #17603A to reach 7.1:1 Bone. Z3 and Z4
  /// are bright (they were the muddy #624806 and #863210) and take ink.
  static const List<Color> backgrounds = [
    NightSession.bgBase, // 0: no HR
    Color(0xFF1C3F6E), // 1: blue
    Color(0xFF155835), // 2: green (brief #17603A)
    Color(0xFFF5CF1F), // 3: true yellow, ink foreground
    Color(0xFFF5822C), // 4: orange, ink foreground
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
  /// title, which keep their own hue only where the fill lets them. [flood]
  /// is the actual fill when it is not the zone's (a run-type flood).
  static Color legibleOn(
    int zone,
    Color colour,
    Color fallback, {
    Color? flood,
  }) => contrast(colour, flood ?? background(zone)) >= 4.5 ? colour : fallback;

  /// The foreground on the bright Z3 / Z4 floods and on run-type floods:
  /// near-black ink.
  static const Color floodInk = NightSession.bgBase;

  /// True for tokens built by [RunFlood] on an ink flood.
  static bool isInk(RunSoloTokens t) => t.inkPrimary == floodInk;

  /// Empty gauge segment on the flood the tokens describe.
  static Color gaugeEmptyFor(RunSoloTokens t) =>
      isInk(t) ? floodInk.withValues(alpha: 0.22) : gaugeEmpty;

  /// Zones from which a coloured label no longer sits on its flood: the amber
  /// and red hues (and the mint phase title) on Z3-Z5 read at 5:1 against a
  /// 7:1 screen, the weakest text on it (design review 11-Oct, S2). Bone there.
  static const int boneLabelsFrom = 3;

  /// The zone's own hue (the time-in-zone chart's) as a label on its fill on
  /// Z1/Z2 only; Bone on Z3-Z5 and with no zone.
  static Color labelOn(int zone, Color fallback) =>
      zone <= 0 || zone >= boneLabelsFrom
      ? fallback
      : legibleOn(zone, distributionDark[zone], fallback);

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

/// What the run screen paints for one moment: the flood, and the foreground
/// that reads on it (>= 7:1, pinned by test/theme_contrast_test.dart).
///
/// - Z1, Z2, Z5: the deep zone fills with Bone.
/// - Z3, Z4: the bright yellow and orange with INK (D1, 11-Oct).
/// - No HR (zone 0): the run type's own colour with whichever of ink or Bone
///   reads better, never black (D3, 11-Oct; brand rule: no-HR days use the
///   run-type colour).
@immutable
class RunFlood {
  const RunFlood._(this.background, this.primary, this.secondary);

  final Color background;

  /// Numbers and anything that must read at a glance.
  final Color primary;

  /// Labels: a touch quieter than [primary], still >= 7:1 on [background].
  final Color secondary;

  /// Ink is used when it reads better than Bone.
  bool get ink => primary != NightSession.inkPrimary;

  static const double minContrast = 7.0;

  factory RunFlood.of(int zone, Color runTypeColour) {
    final z = zone.clamp(0, HrZones.count);
    final bg = z == 0 ? runTypeColour : HrZones.backgrounds[z];
    final useInk = z == 0
        ? HrZones.contrast(HrZones.floodInk, bg) >=
              HrZones.contrast(NightSession.inkPrimary, bg)
        : z == 3 || z == 4;
    if (!useInk) {
      return RunFlood._(bg, NightSession.inkPrimary, HrZones.secondaryOnZone);
    }
    return RunFlood._(bg, HrZones.floodInk, _muted(HrZones.floodInk, bg));
  }

  /// [fg] faded toward [bg] as far as it stays >= [minContrast] + 0.2, at most
  /// 90 % (so the hierarchy exists but never costs legibility).
  static Color _muted(Color fg, Color bg) {
    for (var a = 0.90; a < 1.0; a += 0.01) {
      final c = Color.alphaBlend(fg.withValues(alpha: a), bg);
      if (HrZones.contrast(c, bg) >= minContrast + 0.2) return c;
    }
    return fg;
  }

  /// The theme tokens for everything drawn on this flood. Plates (banners,
  /// PAUSE, STOP, the mute button) turn into a light tint with ink text on
  /// an ink flood; on Bone floods they stay the dark plates.
  RunSoloTokens tokens(RunSoloTokens base) {
    if (!ink) {
      return base.copyWith(inkSecondary: secondary, inkMuted: secondary);
    }
    return base.copyWith(
      inkPrimary: primary,
      inkSecondary: secondary,
      inkMuted: secondary,
      bgBase: background,
      bgRaised: const Color(0x40FFFFFF),
      bgSunken: HrZones.floodInk.withValues(alpha: 0.22),
      lineHair: HrZones.floodInk.withValues(alpha: 0.30),
      semFaster: primary,
      semImproving: primary,
      semSlower: primary,
      semHolding: primary,
      semNoise: secondary,
      semWarn: primary,
      semDanger: primary,
      hrZone: primary,
    );
  }
}
