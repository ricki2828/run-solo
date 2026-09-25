/// Display rows for a Laps run (plan §18.2 post-run column): lap, time,
/// distance, pace, avg HR; fastest lap; spread vs the rep band; HR avg/max;
/// time in the 85–95 % band. Plain arithmetic over `RunFile.laps` and the
/// HR samples so the screen can ship before `RunAnalysis.lapsSummary` lands
/// from run2-engine-fable; swap the source then, keep the rows.
library;

import 'package:flutter/foundation.dart';
import 'package:run_engine/run_engine.dart' as engine;

@immutable
class LapRow {
  const LapRow({
    required this.number,
    required this.durationMs,
    required this.distanceM,
    required this.paceSecPerKm,
    required this.avgHr,
  });
  final int number;
  final int durationMs;
  final double distanceM;
  final double? paceSecPerKm;
  final int? avgHr;
}

@immutable
class LapsView {
  const LapsView({
    required this.rows,
    required this.fastestNumber,
    required this.spreadSecPerKm,
    required this.avgHr,
    required this.maxHr,
    required this.secondsInBand,
  });

  final List<LapRow> rows;
  final int? fastestNumber;

  /// Slowest minus fastest lap, s/km (compare with the rep band).
  final double? spreadSecPerKm;
  final int? avgHr;
  final int? maxHr;

  /// Seconds with HR in 85–95 % of [maxHrUsed] across the whole run.
  final double? secondsInBand;

  static LapsView from(
    engine.RunFile run, {
    required int maxHrUsed,
    engine.EngineConstants constants = engine.EngineConstants.defaults,
  }) {
    final laps = run.laps.where((l) => l.kind != engine.LapKind.pause).toList();
    final rows = <LapRow>[];
    var n = 0;
    for (final lap in laps) {
      n += 1;
      final hrs = run.samples
          .where((s) => s.tMs >= lap.t0Ms && s.tMs < lap.t1Ms && s.hr != null)
          .map((s) => s.hr!)
          .toList();
      final pace = lap.distanceM > 20 && lap.durationMs > 0
          ? lap.durationMs / 1000 / (lap.distanceM / 1000)
          : null;
      rows.add(
        LapRow(
          number: n,
          durationMs: lap.durationMs,
          distanceM: lap.distanceM,
          paceSecPerKm: pace,
          avgHr: hrs.isEmpty
              ? null
              : (hrs.reduce((a, b) => a + b) / hrs.length).round(),
        ),
      );
    }
    final paced = rows.where((r) => r.paceSecPerKm != null).toList();
    LapRow? fastest;
    for (final r in paced) {
      if (fastest == null || r.paceSecPerKm! < fastest.paceSecPerKm!) {
        fastest = r;
      }
    }
    double? spread;
    if (paced.length >= 2) {
      final ps = paced.map((r) => r.paceSecPerKm!).toList()..sort();
      spread = ps.last - ps.first;
    }
    final hrs = run.samples
        .where((s) => s.hr != null)
        .map((s) => s.hr!)
        .toList();
    double? inBand;
    if (hrs.isNotEmpty) {
      final lo = constants.zoneLowFraction * maxHrUsed;
      final hi = constants.zoneHighFraction * maxHrUsed;
      inBand = hrs.where((h) => h >= lo && h <= hi).length.toDouble();
    }
    return LapsView(
      rows: rows,
      fastestNumber: fastest?.number,
      spreadSecPerKm: spread,
      avgHr: hrs.isEmpty
          ? null
          : (hrs.reduce((a, b) => a + b) / hrs.length).round(),
      maxHr: hrs.isEmpty ? null : hrs.reduce((a, b) => a > b ? a : b),
      secondsInBand: inBand,
    );
  }
}

/// Seconds spent in each HR zone 0–5 over the run (run detail strip; zones
/// per addendum A1 shares, no hysteresis needed for a histogram).
List<double> zoneSecondsOf(engine.RunFile run, int maxHrUsed) {
  final out = List<double>.filled(6, 0);
  for (final s in run.samples) {
    final hr = s.hr;
    if (hr == null) {
      out[0] += 1;
      continue;
    }
    final f = hr / maxHrUsed;
    final z = f < 0.6
        ? 1
        : f < 0.7
        ? 2
        : f < 0.8
        ? 3
        : f < 0.9
        ? 4
        : 5;
    out[z] += 1;
  }
  return out;
}
