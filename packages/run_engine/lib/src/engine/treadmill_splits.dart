import '../model/run_file.dart';

/// One stretch between two treadmill markers (the first starts at 0 m, 0 s).
class TreadmillSplit {
  const TreadmillSplit({
    required this.fromM,
    required this.toM,
    required this.ms,
  });
  final double fromM;
  final double toM;
  final int ms;

  double get distanceM => toM - fromM;

  /// Metres per second over the stretch; null when it took no time.
  double? get mps => ms <= 0 ? null : distanceM / (ms / 1000);
}

/// Speeds from treadmill markers. CURRENT is the last stretch (between the
/// last two marks, the first from 0 at the start); AVERAGE is the last
/// marked distance over the moving time at that mark.
class TreadmillSplits {
  const TreadmillSplits._();

  /// Marker spacing: 0.5 km, or 0.25 mi for miles users.
  static const double kmSpacingM = 500;
  static const double miSpacingM = 402.336; // 0.25 mi

  static List<TreadmillSplit> of(List<TreadmillMark> marks) {
    final out = <TreadmillSplit>[];
    var d = 0.0;
    var t = 0;
    for (final m in marks) {
      out.add(TreadmillSplit(fromM: d, toM: m.distanceM, ms: m.activeMs - t));
      d = m.distanceM;
      t = m.activeMs;
    }
    return out;
  }

  static double? currentMps(List<TreadmillMark> marks) =>
      marks.isEmpty ? null : of(marks).last.mps;

  static double? averageMps(List<TreadmillMark> marks) {
    if (marks.isEmpty || marks.last.activeMs <= 0) return null;
    return marks.last.distanceM / (marks.last.activeMs / 1000);
  }

  static double mpsToKmh(double mps) => mps * 3.6;
  static double mpsToMph(double mps) => mps * 3600 / 1609.344;

  /// Seconds per km for a speed in m/s.
  static double secPerKm(double mps) => 1000 / mps;
}
