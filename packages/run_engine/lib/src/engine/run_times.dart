import '../model/run_file.dart';

/// Whole-run time figures the index keeps for every run: moving time and,
/// for a Laps run, the median lap. Pure; reads only the run file.
abstract final class RunTimes {
  /// A final lap shorter than this fraction of the median of the earlier
  /// laps is a partial lap (the stretch from the last press to the stop).
  static const double partialLapFraction = 0.9;

  /// The run's duration minus paused time, ms. The warm-up stays in. Pause
  /// spans are clipped to the run and merged, so overlapping spans are not
  /// counted twice. Never negative.
  static int movingMs(RunFile run) {
    final total = run.end.difference(run.start).inMilliseconds;
    final spans = _merged(run.pauses, 0, total);
    final paused = spans.fold<int>(0, (s, p) => s + (p.$2 - p.$1));
    final moving = total - paused;
    return moving < 0 ? 0 : moving;
  }

  /// The median moving duration of the run's complete laps, seconds; null
  /// when it has no laps to measure. Pause laps are not laps. A final lap
  /// that is clearly partial (under [partialLapFraction] of the median of
  /// the laps before it) is left out; a run's only lap is kept. Time paused
  /// inside a lap is taken out of that lap.
  static double? medianLapSec(RunFile run) {
    final laps = [
      for (final l in run.laps)
        if (l.kind != LapKind.pause) l,
    ];
    if (laps.isEmpty) return null;
    final pauses = _merged(run.pauses, 0, laps.last.t1Ms);
    double moving(Lap l) {
      var paused = 0;
      for (final p in pauses) {
        final a = p.$1 > l.t0Ms ? p.$1 : l.t0Ms;
        final b = p.$2 < l.t1Ms ? p.$2 : l.t1Ms;
        if (b > a) paused += b - a;
      }
      return (l.durationMs - paused) / 1000;
    }

    var secs = [for (final l in laps) moving(l)];
    if (secs.length > 1) {
      final earlier = _median(secs.sublist(0, secs.length - 1));
      if (secs.last < earlier * partialLapFraction) {
        secs = secs.sublist(0, secs.length - 1);
      }
    }
    secs = [
      for (final s in secs)
        if (s > 0) s,
    ];
    return secs.isEmpty ? null : _median(secs);
  }

  static double _median(List<double> v) {
    final s = [...v]..sort();
    final n = s.length;
    return n.isOdd ? s[n ~/ 2] : (s[n ~/ 2 - 1] + s[n ~/ 2]) / 2;
  }

  /// Spans clipped to [lo, hi], sorted and merged where they touch.
  static List<(int, int)> _merged(List<Span> spans, int lo, int hi) {
    final clipped = [
      for (final p in spans)
        if (p.t1Ms > lo && p.t0Ms < hi)
          (p.t0Ms < lo ? lo : p.t0Ms, p.t1Ms > hi ? hi : p.t1Ms),
    ]..sort((a, b) => a.$1.compareTo(b.$1));
    final out = <(int, int)>[];
    for (final c in clipped) {
      if (out.isNotEmpty && c.$1 <= out.last.$2) {
        if (c.$2 > out.last.$2) out[out.length - 1] = (out.last.$1, c.$2);
      } else {
        out.add(c);
      }
    }
    return out;
  }
}
