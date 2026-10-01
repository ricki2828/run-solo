import 'package:run_engine/run_engine.dart' as engine;

import 'format.dart';

/// Compact display only. The source comparison retains its qualified bound
/// when a value lies outside the measured 10th-90th reference table.
abstract final class IdentityDisplay {
  static String? percentileNumber(String? comparison) {
    if (comparison == null) return null;
    final match = RegExp(r'(\d+)(?:st|nd|rd|th)$').firstMatch(comparison);
    return match?.group(1);
  }

  static String? equivalentTime(engine.IdentityScore score) {
    final metres = switch (score.lane) {
      engine.IdentityLane.speed => 1000.0,
      engine.IdentityLane.mid => 5000.0,
      engine.IdentityLane.long => 21097.5,
      engine.IdentityLane.aerobic => null,
    };
    if (metres == null) return null;
    final seconds = engine.RacePercentileNorms.equivalentSeconds(
      score.vdot,
      metres,
    );
    if (seconds == null) return null;
    return Fmt.clock((seconds * 1000).round());
  }

  static String? equivalentLabel(engine.IdentityLane lane) => switch (lane) {
    engine.IdentityLane.speed => 'Race-pace guess, 1K',
    engine.IdentityLane.mid => 'Race-pace guess, 5K',
    engine.IdentityLane.long => 'Race-pace guess, half marathon',
    engine.IdentityLane.aerobic => null,
  };
}
