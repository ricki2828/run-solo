/// The in-run grade as a word and a colour (Ricki, 14-Oct: "grade doesn't
/// mean much"). Fixed thresholds so the word means the same every run.
library;

import 'package:flutter/material.dart';

import 'tokens.dart';

enum GradeBand {
  flat('Flat', AuroraGrade.flat),
  gentle('Gentle', AuroraGrade.gentle),
  climb('Climb', AuroraGrade.climb),
  steep('Steep', AuroraGrade.steep),
  verySteep('Very steep', AuroraGrade.verySteep),
  down('Down', AuroraGrade.down),
  steepDown('Steep down', AuroraGrade.steepDown);

  const GradeBand(this.word, this.fill);

  /// The word on the chip.
  final String word;

  /// The chip's fill.
  final Color fill;

  /// Text on the chip: near-black on the pale fills, white on the dark ones,
  /// whichever reads better.
  Color get ink {
    const dark = NightSession.bgBase;
    return _contrast(dark, fill) >= _contrast(Colors.white, fill)
        ? dark
        : Colors.white;
  }

  /// Flat under 2 %, Gentle 2 to 5, Climb 5 to 8, Steep 8 to 12, Very steep
  /// over 12. Downhill: Down from -2 to -8, Steep down below that. Null when
  /// there is no grade yet.
  static GradeBand? of(double? pct) {
    if (pct == null) return null;
    if (pct <= -8) return steepDown;
    if (pct <= -2) return down;
    if (pct < 2) return flat;
    if (pct < 5) return gentle;
    if (pct < 8) return climb;
    if (pct <= 12) return steep;
    return verySteep;
  }

  static double _contrast(Color a, Color b) {
    final la = a.computeLuminance(), lb = b.computeLuminance();
    final hi = la > lb ? la : lb, lo = la > lb ? lb : la;
    return (hi + 0.05) / (lo + 0.05);
  }
}
