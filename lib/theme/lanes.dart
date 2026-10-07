import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:run_engine/run_engine.dart' as engine;

import 'tokens.dart';

double _lum(Color c) {
  double ch(double v) =>
      v <= 0.03928 ? v / 12.92 : math.pow((v + 0.055) / 1.055, 2.4).toDouble();
  return 0.2126 * ch(c.r) + 0.7152 * ch(c.g) + 0.0722 * ch(c.b);
}

/// WCAG contrast ratio of two opaque colours.
double contrastRatio(Color a, Color b) {
  final la = _lum(a), lb = _lum(b);
  return (math.max(la, lb) + 0.05) / (math.min(la, lb) + 0.05);
}

/// Each score takes the colour of the run type that builds it (the same
/// colours as Home's unlock dots). Fills (bars, ticks, sparklines, big
/// numbers at 24 sp+) use the bright token; small text uses [textOn].
extension LaneColours on RunSoloTokens {
  Color laneFill(engine.IdentityLane lane) => switch (lane) {
    engine.IdentityLane.aerobic => typeTests,
    engine.IdentityLane.speed => typeIntervals,
    engine.IdentityLane.mid => typeGoal,
    engine.IdentityLane.long => typeFree,
  };

  Color laneText(engine.IdentityLane lane) => textOn(laneFill(lane));

  /// [c] nudged in lightness, same hue, until it reads at [min]:1 on both
  /// the ground and the raised surface. Fills stay bright; only text moves.
  Color textOn(Color c, {double min = 4.5}) {
    bool ok(Color x) =>
        contrastRatio(x, bgBase) >= min && contrastRatio(x, bgRaised) >= min;
    if (ok(c)) return c;
    final hsl = HSLColor.fromColor(c);
    final lightGround = _lum(bgBase) > 0.5;
    var l = hsl.lightness;
    var out = c;
    while (!ok(out) && l > 0 && l < 1) {
      l += lightGround ? -0.005 : 0.005;
      out = hsl.withLightness(l.clamp(0.0, 1.0)).toColor();
    }
    return out;
  }
}
