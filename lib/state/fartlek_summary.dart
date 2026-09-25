/// Fartlek post-run summary (Phase 3 plan §3.5, D3): the runner pressed LAP
/// at the start and end of each surge, so after the first press odd laps
/// (0-based) are surges and even laps easy running. No verdict word; the
/// lap table stays underneath.
library;

import 'package:flutter/foundation.dart';
import 'package:run_engine/run_engine.dart' as engine;

@immutable
class FartlekSummary {
  const FartlekSummary({
    required this.surges,
    required this.surgeSeconds,
    required this.surgePaceSecPerKm,
    required this.easyPaceSecPerKm,
    this.timeInBandSeconds,
  });

  /// Surge laps that covered ground.
  final int surges;
  final double surgeSeconds;

  /// Total surge time ÷ total surge distance; null with no surge distance.
  final double? surgePaceSecPerKm;

  /// Same over the easy laps between and after surges (the lap before the
  /// first press is warm-up and not counted).
  final double? easyPaceSecPerKm;

  /// HR time in the Laps band (85–95 % of max), when a strap was on.
  final double? timeInBandSeconds;

  /// Null when there is no lap table or no surge at all.
  static FartlekSummary? of(engine.LapsSummary? laps) {
    if (laps == null) return null;
    var surges = 0;
    var surgeS = 0.0, surgeM = 0.0, easyS = 0.0, easyM = 0.0;
    for (var i = 0; i < laps.laps.length; i++) {
      final l = laps.laps[i];
      if (i.isOdd) {
        if (l.distanceM <= 0) continue;
        surges += 1;
        surgeS += l.movingSeconds;
        surgeM += l.distanceM;
      } else if (i > 0) {
        easyS += l.movingSeconds;
        easyM += l.distanceM;
      }
    }
    if (surges == 0) return null;
    return FartlekSummary(
      surges: surges,
      surgeSeconds: surgeS,
      surgePaceSecPerKm: surgeM > 0 ? surgeS / (surgeM / 1000) : null,
      easyPaceSecPerKm: easyM > 0 ? easyS / (easyM / 1000) : null,
      timeInBandSeconds: laps.hrPresent ? laps.timeInBandSeconds : null,
    );
  }
}
