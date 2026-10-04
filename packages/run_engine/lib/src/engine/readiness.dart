import '../model/run_file.dart';

/// A resting-HR proxy from a run's first minutes: the lowest 2-minute mean
/// heart rate in the first [lookMs] of the run, while the runner is still
/// standing or walking. Not a true resting reading (that needs a morning,
/// lying down), so it is only ever compared with the runner's own earlier
/// readings taken the same way.
///
/// Null when there is no strap, too little HR in the window, the runner
/// was already running, or the figure is not plausible for a rest-ish
/// start (above [maxPlausibleBpm]).
abstract final class RestingHr {
  static const int lookMs = 6 * 60 * 1000;
  static const int windowMs = 2 * 60 * 1000;

  /// A window needs HR on at least this share of its seconds.
  static const double minCoverage = 0.75;

  /// Walking or standing: mean speed over the window at or below this.
  static const double maxWindowSpeedMps = 2.0;

  static const int minPlausibleBpm = 30;
  static const int maxPlausibleBpm = 110;

  static int? of(RunFile run) {
    final head = [
      for (final s in run.samples)
        if (s.tMs <= lookMs + windowMs) s,
    ];
    if (head.length < windowMs ~/ 1000) return null;
    double? best;
    // Windows start every second inside the look window.
    for (var i = 0; i < head.length; i++) {
      final from = head[i].tMs;
      if (from > lookMs) break;
      var n = 0, hrN = 0;
      var hrSum = 0.0, speedSum = 0.0, speedN = 0;
      for (var j = i; j < head.length && head[j].tMs < from + windowMs; j++) {
        n++;
        final hr = head[j].hr;
        if (hr != null) {
          hrN++;
          hrSum += hr;
        }
        final v = head[j].speedMps;
        if (v != null) {
          speedSum += v;
          speedN++;
        }
      }
      if (n < windowMs ~/ 1000 * 0.9) break; // ran out of samples
      if (hrN < n * minCoverage) continue;
      if (speedN > 0 && speedSum / speedN > maxWindowSpeedMps) continue;
      final mean = hrSum / hrN;
      if (best == null || mean < best) best = mean;
    }
    if (best == null) return null;
    final bpm = best.round();
    return bpm < minPlausibleBpm || bpm > maxPlausibleBpm ? null : bpm;
  }
}

/// The daily readiness line: today's resting-HR proxy against the runner's
/// own 7-day baseline (the median of readings in the 7 days before it).
/// Hidden ([of] returns null) with no recent reading or fewer than
/// [minBaseline] readings behind the baseline.
///
/// Research-based and rough: a resting HR several beats above one's own
/// norm is a commonly used sign of fatigue, illness or poor recovery, but
/// day-to-day noise is real (a few bpm), so one reading only ever moves the
/// line from "normal" to "take it easy" when it is [easyAtBpm] or more over.
class Readiness {
  const Readiness._({
    required this.latestBpm,
    required this.baselineBpm,
    required this.baselineRuns,
  });

  /// Take it easy at this many bpm over the baseline.
  static const int easyAtBpm = 5;
  static const int minBaseline = 3;
  static const int baselineDays = 7;

  /// The reading must be this fresh (days) for the line to show.
  static const int freshDays = 2;

  final int latestBpm;
  final int baselineBpm;
  final int baselineRuns;

  int get delta => latestBpm - baselineBpm;
  bool get takeItEasy => delta >= easyAtBpm;

  /// "Recovered: resting HR normal" / "Take it easy: resting HR up 6 bpm".
  String get line => takeItEasy
      ? 'Take it easy: resting HR up $delta bpm'
      : 'Recovered: resting HR normal';

  /// The detail view: numbers, how it is measured, and the caveat.
  String get detail =>
      'Resting HR $latestBpm bpm today, against $baselineBpm bpm over your '
      'last $baselineRuns runs. It is the lowest 2 minutes of your first '
      'few minutes, so it only compares with your own runs. Research-based '
      'rough guide, not a medical reading.';

  static Readiness? of(
    Iterable<({DateTime date, int bpm})> readings, {
    required DateTime now,
  }) {
    final sorted = readings.toList()..sort((a, b) => b.date.compareTo(a.date));
    if (sorted.isEmpty) return null;
    final latest = sorted.first;
    if (now.difference(latest.date) > const Duration(days: freshDays) ||
        latest.date.isAfter(now)) {
      return null;
    }
    final from = latest.date.subtract(const Duration(days: baselineDays));
    final base = [
      for (final r in sorted.skip(1))
        if (r.date.isAfter(from) && r.date.isBefore(latest.date)) r.bpm,
    ]..sort();
    if (base.length < minBaseline) return null;
    final mid = base.length ~/ 2;
    final median = base.length.isOdd
        ? base[mid].toDouble()
        : (base[mid - 1] + base[mid]) / 2;
    return Readiness._(
      latestBpm: latest.bpm,
      baselineBpm: median.round(),
      baselineRuns: base.length,
    );
  }
}
