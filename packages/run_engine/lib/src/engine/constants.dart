import 'dart:math' as math;

import '../model/session_catalogue.dart';
import '../model/session_spec.dart';

/// Seeded engine constants (plan §5). Calibrated from the founder's fixtures
/// before the closed test; every verdict stores the values it used.
class EngineConstants {
  const EngineConstants({
    this.runFloorSecPerKm = 10,
    this.repBandSecPerKm = 10,
    this.trimStartMs = 12000,
    this.trimEndMs = 5000,
    this.pauseInterruptMs = 20000,
    this.sampleGapInterruptMs = 10000,
    this.workVsRecoveryMinRatio = 1.15,
    this.presetToleranceMs = 30000,
    this.indoorFixShareBelow = 0.10,
    this.noisyQualityBelow = 0.80,
    this.qualityMaxGapMs = 5000,
    this.qualityMaxAccuracyM = 25,
    this.zoneLowFraction = 0.85,
    this.zoneHighFraction = 0.95,
    this.medianSetSize = 6,
    this.bestBadgeFraction = 0.01,
    this.scoredLapMinSeconds = 60,
    this.scoredLapMinMetres = 100,
  });

  /// Run-to-run noise floor for work and recovery pace, s/km.
  final double runFloorSecPerKm;

  /// Within-session rep spread band, s/km (not 6: phone GPS is ±5–10 s/km).
  final double repBandSecPerKm;

  /// Lap-bounded reps trim the first 12 s (GPS lag) and the last 5 s.
  final int trimStartMs;
  final int trimEndMs;

  /// A pause longer than this inside a rep marks it `interrupted`.
  final int pauseInterruptMs;

  /// A sample gap longer than this inside a rep marks it `interrupted`.
  final int sampleGapInterruptMs;

  /// Work must be at least this much faster (speed ratio) than adjacent recovery.
  final double workVsRecoveryMinRatio;

  /// Preset phase durations match within ± this.
  final int presetToleranceMs;

  /// `indoor` when fewer than this share of samples have a fix.
  final double indoorFixShareBelow;

  /// `noisy` when gps_quality is below this.
  final double noisyQualityBelow;
  final int qualityMaxGapMs;
  final double qualityMaxAccuracyM;

  /// Time-in-zone window as a fraction of max HR.
  final double zoneLowFraction;
  final double zoneHighFraction;

  /// Run 3+ compares against the median of this many prior runs.
  final int medianSetSize;

  /// 365-day best badge needs > this fraction better than the best prior.
  final double bestBadgeFraction;

  /// A Laps-run lap counts for fastest/spread only past both of these (a
  /// short tail after the last press is listed, never scored).
  final double scoredLapMinSeconds;
  final double scoredLapMinMetres;

  /// Run 2 compares single vs single, doubling the variance: floor × sqrt(2).
  double get run2FloorSecPerKm => runFloorSecPerKm * math.sqrt2;

  /// Noise floor for comparison key [key], s/km (Phase 3 plan §3.7,
  /// eng-review W1). Fixed per key, never from a run's own rep count:
  /// - `t240x*` (every 4x4, 3–6 reps): [runFloorSecPerKm], as in Phase 2, so
  ///   no migrated 4x4 verdict changes;
  /// - any other key: `floor × sqrt(16 min ÷ nominal work minutes)`, clamped
  ///   to 1–2 × [runFloorSecPerKm] (10–20 s/km). The nominal session is the
  ///   catalogue preset whose default owns the key, else the template's own
  ///   default passed as [templateDefault] (custom keys).
  /// Seeded; calibrated in Phase 3 I3/I5 against the founder's runs.
  double floorSecPerKmForKey(String key, {SessionSpec? templateDefault}) {
    if (key == ComparisonKey.norwegian4x4) return runFloorSecPerKm;
    final nominal =
        SessionCatalogue.ownerOfKey(key)?.defaults ?? templateDefault;
    final seconds = nominal == null ? 0 : nominalWorkSeconds(nominal);
    if (seconds <= 0) return runFloorSecPerKm;
    final f = runFloorSecPerKm * math.sqrt(16 * 60 / seconds);
    return f.clamp(runFloorSecPerKm, 2 * runFloorSecPerKm).toDouble();
  }

  /// Distance keys state the floor per rep (the headline is rep time):
  /// `floor_s_per_rep = floor_s_per_km × nominal_km` (400 m at 12 s/km →
  /// 4.8 s).
  static double floorSecPerRep(double floorSecPerKm, int repMetres) =>
      floorSecPerKm * repMetres / 1000;

  /// Pace assumed to turn distance work into minutes for the floor formula
  /// (seed, calibrated with the floors).
  static const int nominalDistancePaceSecPerKm = 300;

  /// Total work seconds of [spec]: time steps as written, distance steps at
  /// [nominalDistancePaceSecPerKm].
  static int nominalWorkSeconds(SessionSpec spec) {
    var total = 0.0;
    for (final s in spec.workSteps) {
      total += switch (s.target) {
        TargetKind.time => s.value,
        TargetKind.distance => s.value / 1000 * nominalDistancePaceSecPerKm,
        TargetKind.equalToPreviousWork => 0,
      };
    }
    return total.round();
  }

  /// Fixed windows for by-feel runs with no preset (plan §5).
  static const int byFeelWorkMinMs = 210000; // 3:30
  static const int byFeelWorkMaxMs = 270000; // 4:30
  static const int byFeelRecoveryMinMs = 120000; // 2:00
  static const int byFeelRecoveryMaxMs = 300000; // 5:00
  static const int minReps = 3;
  static const int maxReps = 6;

  static const EngineConstants defaults = EngineConstants();
}
