/// Display helpers for run detail that are not engine metrics.
library;

import 'package:flutter/foundation.dart' show immutable;
import 'package:run_engine/run_engine.dart' as engine;

/// Moving seconds spent in each HR zone 0-5 over the run (run detail
/// "Time in zone"; the runner's chosen [zones], no hysteresis needed for a
/// histogram). Index 0 is moving time with no heart rate. Paused time
/// (manual and auto) counts nowhere.
List<double> zoneSecondsOf(engine.RunFile run, engine.HrZones zones) {
  final out = List<double>.filled(6, 0);
  final samples = run.samples;
  final pauses = _merged(run.pauses);
  for (var i = 0; i < samples.length; i++) {
    final s = samples[i];
    // Weight by the gap to the next sample, capped so a dropout does not
    // credit minutes to one reading.
    final dtMs = i + 1 < samples.length
        ? (samples[i + 1].tMs - s.tMs).clamp(0, 5000)
        : 1000;
    final dt = (dtMs - _pausedWithin(pauses, s.tMs, s.tMs + dtMs)) / 1000;
    if (dt <= 0) continue;
    final hr = s.hr;
    if (hr == null) {
      out[0] += dt;
      continue;
    }
    final z = zones.zoneOf(hr);
    out[z] += dt;
  }
  return out;
}

/// The zone (1-5) a run mostly ran in over the samples [inWindow] accepts,
/// weighted by time like [zoneSecondsOf]; null when none of them has a
/// heart rate. Charts colour a rep, lap or split by this.
int? dominantZoneOf(
  engine.RunFile run,
  engine.HrZones zones,
  bool Function(engine.Sample s) inWindow,
) {
  final samples = run.samples;
  final secs = List<double>.filled(6, 0);
  for (var i = 0; i < samples.length; i++) {
    final s = samples[i];
    final hr = s.hr;
    if (hr == null || !inWindow(s)) continue;
    final dtMs = i + 1 < samples.length
        ? (samples[i + 1].tMs - s.tMs).clamp(0, 5000)
        : 1000;
    secs[zones.zoneOf(hr)] += dtMs / 1000;
  }
  var best = 0;
  for (var z = 1; z <= 5; z++) {
    if (secs[z] > secs[best]) best = z;
  }
  return best == 0 ? null : best;
}

/// A run's moving heart-rate seconds by bpm, kept in the index so the zone
/// split can be worked out at view time from the runner's CURRENT zones: a
/// change of zone method needs no re-index. One entry per bpm from
/// [minBpm]; seconds are whole.
@immutable
class HrHist {
  const HrHist(this.minBpm, this.secs);

  final int minBpm;
  final List<int> secs;

  /// Null with no heart rate at all. Same sample weighting as
  /// [zoneSecondsOf] (pauses count nowhere).
  static HrHist? of(engine.RunFile run) {
    final samples = run.samples;
    final pauses = _merged(run.pauses);
    final acc = <int, double>{};
    for (var i = 0; i < samples.length; i++) {
      final s = samples[i];
      final hr = s.hr;
      if (hr == null) continue;
      final dtMs = i + 1 < samples.length
          ? (samples[i + 1].tMs - s.tMs).clamp(0, 5000)
          : 1000;
      final dt = (dtMs - _pausedWithin(pauses, s.tMs, s.tMs + dtMs)) / 1000;
      if (dt <= 0) continue;
      final bpm = hr.round();
      acc[bpm] = (acc[bpm] ?? 0) + dt;
    }
    if (acc.isEmpty) return null;
    final lo = acc.keys.reduce((a, b) => a < b ? a : b);
    final hi = acc.keys.reduce((a, b) => a > b ? a : b);
    return HrHist(lo, [for (var b = lo; b <= hi; b++) (acc[b] ?? 0).round()]);
  }

  /// Seconds in zones 1-5 under [zones], in [zoneSecondsOf]'s layout (slot 0
  /// is unused here).
  List<double> zoneSeconds(engine.HrZones zones) {
    final out = List<double>.filled(6, 0);
    for (var i = 0; i < secs.length; i++) {
      if (secs[i] > 0) out[zones.zoneOf(minBpm + i)] += secs[i];
    }
    return out;
  }

  List<int> toJson() => [minBpm, ...secs];

  static HrHist? fromJson(Object? j) {
    if (j is! List || j.length < 2) return null;
    return HrHist((j.first as num).toInt(), [
      for (final v in j.skip(1)) (v as num).toInt(),
    ]);
  }
}

/// Average heart rate over moving time that has a reading, and the share of
/// moving time that had one (0 to 1); null with no heart rate at all. The
/// same sample weighting as [zoneSecondsOf], so the two never disagree.
({double avgHr, double coverage})? hrSummaryOf(engine.RunFile run) {
  final samples = run.samples;
  final pauses = _merged(run.pauses);
  var withHr = 0.0, moving = 0.0, weighted = 0.0;
  for (var i = 0; i < samples.length; i++) {
    final s = samples[i];
    final dtMs = i + 1 < samples.length
        ? (samples[i + 1].tMs - s.tMs).clamp(0, 5000)
        : 1000;
    final dt = (dtMs - _pausedWithin(pauses, s.tMs, s.tMs + dtMs)) / 1000;
    if (dt <= 0) continue;
    moving += dt;
    final hr = s.hr;
    if (hr == null) continue;
    withHr += dt;
    weighted += hr * dt;
  }
  if (withHr <= 0 || moving <= 0) return null;
  return (avgHr: weighted / withHr, coverage: withHr / moving);
}

List<engine.Span> _merged(List<engine.Span> spans) {
  final sorted = [...spans]..sort((a, b) => a.t0Ms.compareTo(b.t0Ms));
  final out = <engine.Span>[];
  for (final s in sorted) {
    if (out.isNotEmpty && s.t0Ms <= out.last.t1Ms) {
      if (s.t1Ms > out.last.t1Ms) {
        out[out.length - 1] = engine.Span(out.last.t0Ms, s.t1Ms);
      }
    } else {
      out.add(engine.Span(s.t0Ms, s.t1Ms));
    }
  }
  return out;
}

int _pausedWithin(List<engine.Span> merged, int aMs, int bMs) {
  var ms = 0;
  for (final p in merged) {
    if (p.t0Ms >= bMs) break;
    if (p.t1Ms <= aMs) continue;
    ms += (p.t1Ms < bMs ? p.t1Ms : bMs) - (p.t0Ms > aMs ? p.t0Ms : aMs);
  }
  return ms;
}

/// The share of heart-rate time in Z1-Z5, ready to draw.
class ZoneShares {
  ZoneShares._(this.seconds, this.percents, this.hrCoverage);

  /// From [zoneSecondsOf]'s six slots. Null when no moving time has a
  /// reading.
  static ZoneShares? from(List<double> zoneSeconds) {
    final hr = [for (var z = 1; z <= 5; z++) zoneSeconds[z]];
    final total = hr.fold(0.0, (a, b) => a + b);
    if (total <= 0) return null;
    final moving = total + zoneSeconds[0];
    return ZoneShares._(hr, _largestRemainder(hr, total), total / moving);
  }

  /// Seconds in Z1..Z5 (index 0 is Z1).
  final List<double> seconds;

  /// Whole percents for Z1..Z5 of heart-rate time, largest remainder, so
  /// they always sum to 100. A zone with no time is always 0; a zone with a
  /// sliver can still round to 0.
  final List<int> percents;

  /// Share of moving time that had a heart rate, 0-1.
  final double hrCoverage;

  /// The note for a run with a strap that dropped out, null when HR covers
  /// (nearly) the whole run.
  String? get partialNote {
    final pct = (hrCoverage * 100).floor();
    return pct >= 99 ? null : 'Heart rate for $pct% of the run';
  }

  static List<int> _largestRemainder(List<double> parts, double total) {
    final exact = [for (final p in parts) p / total * 100];
    final out = [for (final e in exact) e.floor()];
    var left = 100 - out.fold(0, (a, b) => a + b);
    final order = List<int>.generate(parts.length, (i) => i)
      ..sort((a, b) {
        final byFrac = (exact[b] - out[b]).compareTo(exact[a] - out[a]);
        return byFrac != 0 ? byFrac : a.compareTo(b);
      });
    for (final i in order) {
      if (left == 0) break;
      if (parts[i] <= 0) continue;
      out[i] += 1;
      left -= 1;
    }
    return out;
  }
}
