import '../model/run_file.dart';
import '../model/session_spec.dart';

/// Whole-run time figures the index keeps for every run: moving time and,
/// for a Laps run, the median lap. Pure; reads only the run file.
abstract final class RunTimes {
  /// A final lap that covered less than this fraction of the median
  /// distance of the laps before it is partial (the stretch from the last
  /// press to the stop).
  static const double partialLapFraction = 0.9;

  /// Laps whose distances differ from the median by more than this fraction
  /// are variable-length (a fartlek, intervals by feel): a median lap time
  /// means nothing there.
  static const double lapSpreadLimit = 0.25;

  /// The run's duration minus paused time and recording gaps, ms. The
  /// warm-up stays in. Pause and gap spans are clipped to the run and
  /// merged, so overlaps (a gap inside a pause) are not counted twice.
  /// Never negative. A run with no pause or gap spans (one recorded before
  /// they existed) is its elapsed time.
  static int movingMs(RunFile run) {
    final total = run.end.difference(run.start).inMilliseconds;
    final spans = _merged([...run.pauses, ...run.gaps], 0, total);
    final out = spans.fold<int>(0, (s, p) => s + (p.$2 - p.$1));
    final moving = total - out;
    return moving < 0 ? 0 : moving;
  }

  /// The median moving duration of the run's complete laps, seconds, for
  /// a lap run whose laps are all about the same length. Null when:
  /// - there are no laps, or it is a fartlek (laps are not a distance);
  /// - the laps have no GPS distance to judge them by (indoor);
  /// - any lap's distance is more than [lapSpreadLimit] from the median
  ///   distance (variable-length laps).
  /// Pause laps are not laps. The final lap is dropped when it is partial:
  /// under [partialLapFraction] of the median distance of the laps before
  /// it, however fast it was run. A run's only lap is kept. Time paused (or
  /// lost to a gap) inside a lap is taken out of that lap.
  static double? medianLapSec(RunFile run) {
    if (run.session?.templateId == SessionSpec.fartlekId) return null;
    var laps = [
      for (final l in run.laps)
        if (l.kind != LapKind.pause) l,
    ];
    if (laps.isEmpty) return null;
    if (laps.length > 1) {
      final earlier = _median([
        for (final l in laps.sublist(0, laps.length - 1)) l.distanceM,
      ]);
      if (laps.last.distanceM < earlier * partialLapFraction) {
        laps = laps.sublist(0, laps.length - 1);
      }
    }
    final medianM = _median([for (final l in laps) l.distanceM]);
    if (medianM <= 0) return null;
    for (final l in laps) {
      if ((l.distanceM - medianM).abs() > medianM * lapSpreadLimit) {
        return null;
      }
    }
    final out = _merged([...run.pauses, ...run.gaps], 0, laps.last.t1Ms);
    double moving(Lap l) {
      var lost = 0;
      for (final p in out) {
        final a = p.$1 > l.t0Ms ? p.$1 : l.t0Ms;
        final b = p.$2 < l.t1Ms ? p.$2 : l.t1Ms;
        if (b > a) lost += b - a;
      }
      return (l.durationMs - lost) / 1000;
    }

    final secs = [
      for (final l in laps)
        if (moving(l) > 0) moving(l),
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
