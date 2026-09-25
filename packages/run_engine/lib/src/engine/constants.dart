import 'dart:math' as math;

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

  /// Fixed windows for by-feel runs with no preset (plan §5).
  static const int byFeelWorkMinMs = 210000; // 3:30
  static const int byFeelWorkMaxMs = 270000; // 4:30
  static const int byFeelRecoveryMinMs = 120000; // 2:00
  static const int byFeelRecoveryMaxMs = 300000; // 5:00
  static const int minReps = 3;
  static const int maxReps = 6;

  static const EngineConstants defaults = EngineConstants();
}
