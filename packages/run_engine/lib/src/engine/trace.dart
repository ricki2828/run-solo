import '../model/run_file.dart';

/// Read-only helpers over the sample stream. Every pace the engine reports is
/// Δdistance ÷ Δtime over a window, never a mean of per-sample speed.
class Trace {
  Trace(this.samples);

  final List<Sample> samples;

  bool get isEmpty => samples.isEmpty;

  int get startMs => samples.isEmpty ? 0 : samples.first.tMs;
  int get endMs => samples.isEmpty ? 0 : samples.last.tMs;

  /// Index of the last sample with `t <= tMs`, or -1 before the first.
  int indexAtOrBefore(int tMs) {
    var lo = 0;
    var hi = samples.length - 1;
    var ans = -1;
    while (lo <= hi) {
      final mid = (lo + hi) >> 1;
      if (samples[mid].tMs <= tMs) {
        ans = mid;
        lo = mid + 1;
      } else {
        hi = mid - 1;
      }
    }
    return ans;
  }

  /// Cumulative distance at `tMs`, linearly interpolated between samples and
  /// clamped to the ends.
  double distAt(int tMs) {
    if (samples.isEmpty) return 0;
    if (tMs <= samples.first.tMs) return samples.first.distM;
    if (tMs >= samples.last.tMs) return samples.last.distM;
    final i = indexAtOrBefore(tMs);
    final a = samples[i];
    final b = samples[i + 1];
    if (a.tMs == tMs) return a.distM;
    final f = (tMs - a.tMs) / (b.tMs - a.tMs);
    return a.distM + (b.distM - a.distM) * f;
  }

  /// Samples with `aMs <= t < bMs`.
  Iterable<Sample> between(int aMs, int bMs) sync* {
    var i = indexAtOrBefore(aMs);
    if (i < 0 || samples[i].tMs < aMs) i++;
    for (; i < samples.length && samples[i].tMs < bMs; i++) {
      yield samples[i];
    }
  }

  /// Largest gap between consecutive samples inside `[aMs, bMs]`, including
  /// the lead-in from `aMs` to the first sample and out to `bMs`.
  ///
  /// Spans in [excluding] (pauses) do not count as gaps: their overlap with
  /// each sample-to-sample interval is subtracted.
  int maxSampleGapMs(int aMs, int bMs, {List<Span> excluding = const []}) {
    int gap(int from, int to) {
      var g = to - from;
      for (final p in excluding) {
        final lo = p.t0Ms > from ? p.t0Ms : from;
        final hi = p.t1Ms < to ? p.t1Ms : to;
        if (hi > lo) g -= hi - lo;
      }
      return g;
    }

    var maxGap = 0;
    var prev = aMs;
    for (final s in between(aMs, bMs)) {
      final g = gap(prev, s.tMs);
      if (g > maxGap) maxGap = g;
      prev = s.tMs;
    }
    final last = gap(prev, bMs);
    if (last > maxGap) maxGap = last;
    return maxGap;
  }

  /// Share of samples with a fix.
  double fixShare() {
    if (samples.isEmpty) return 0;
    final withFix = samples.where((s) => s.hasFix).length;
    return withFix / samples.length;
  }

  /// gps_quality (plan §5): share of samples with a fix, accuracy <= 25 m and
  /// a gap <= 5 s to the previous sample.
  double quality({required int maxGapMs, required double maxAccuracyM}) {
    if (samples.isEmpty) return 0;
    var good = 0;
    for (var i = 0; i < samples.length; i++) {
      final s = samples[i];
      if (!s.hasFix) continue;
      if (s.accM != null && s.accM! > maxAccuracyM) continue;
      if (i > 0 && s.tMs - samples[i - 1].tMs > maxGapMs) continue;
      good++;
    }
    return good / samples.length;
  }

  /// Mean HR over `[aMs, bMs)` weighted by sample spacing, or null.
  double? meanHr(int aMs, int bMs) {
    var beats = 0.0;
    var seconds = 0.0;
    Sample? prev;
    for (final s in between(aMs, bMs)) {
      if (prev != null && prev.hr != null) {
        final dt = (s.tMs - prev.tMs) / 1000;
        beats += prev.hr! * dt;
        seconds += dt;
      }
      prev = s;
    }
    if (prev != null && prev.hr != null && bMs > prev.tMs) {
      final dt = (bMs - prev.tMs) / 1000;
      beats += prev.hr! * dt;
      seconds += dt;
    }
    return seconds == 0 ? null : beats / seconds;
  }

  int? peakHr(int aMs, int bMs) {
    int? peak;
    for (final s in between(aMs, bMs)) {
      if (s.hr != null && (peak == null || s.hr! > peak)) peak = s.hr;
    }
    return peak;
  }

  /// Seconds inside `[aMs, bMs)` where HR is within `[low, high]` bpm.
  double secondsInZone(int aMs, int bMs, double low, double high) {
    var seconds = 0.0;
    Sample? prev;
    for (final s in between(aMs, bMs)) {
      if (prev != null && prev.hr != null) {
        final hr = prev.hr!;
        if (hr >= low && hr <= high) seconds += (s.tMs - prev.tMs) / 1000;
      }
      prev = s;
    }
    if (prev != null && prev.hr != null && bMs > prev.tMs) {
      final hr = prev.hr!;
      if (hr >= low && hr <= high) seconds += (bMs - prev.tMs) / 1000;
    }
    return seconds;
  }

  /// Highest *sustained* 30 s mean HR across the run, or null without HR.
  ///
  /// A window counts only when it holds at least [minReadings] HR readings
  /// (27 s of coverage at the 1 Hz sample rate), no two consecutive readings
  /// inside it are more than [maxHrGapMs] apart, and the last reading is
  /// within [maxHrGapMs] of the window end. Otherwise a spike followed by a
  /// strap dropout (the dry-contact case D3 item 5 guards against) would
  /// "average" to the spike, because [meanHr] weights only the seconds that
  /// have HR. Coverage counts readings, not held time, so a burst just
  /// before a dropout cannot borrow the trailing hold to reach the bar.
  /// A short burst inside an otherwise valid window still moves that
  /// window's mean by a few bpm; that is a sustained value, not an artefact.
  double? highest30sHr({
    int windowMs = 30000,
    int minReadings = 27,
    int maxHrGapMs = 3000,
  }) {
    double? best;
    for (var i = 0; i < samples.length; i++) {
      final a = samples[i];
      if (a.hr == null) continue;
      final end = a.tMs + windowMs;
      if (samples.last.tMs - a.tMs < windowMs) break;
      // Coverage and gap check over the HR readings in [a.t, end).
      var readings = 0;
      var ok = true;
      Sample? prev;
      for (final s in between(a.tMs, end)) {
        if (s.hr == null) continue;
        if (prev != null && s.tMs - prev.tMs > maxHrGapMs) {
          ok = false;
          break;
        }
        readings++;
        prev = s;
      }
      if (!ok || prev == null) continue;
      if (end - prev.tMs > maxHrGapMs) continue;
      if (readings < minReadings) continue;
      final mean = meanHr(a.tMs, end);
      if (mean == null) continue;
      if (best == null || mean > best) best = mean;
    }
    return best;
  }

  /// Like [meanHr] but ignoring every interval inside [excluding] (pauses).
  double? meanHrExcluding(int aMs, int bMs, List<Span> excluding) {
    if (excluding.isEmpty) return meanHr(aMs, bMs);
    var beats = 0.0;
    var seconds = 0.0;
    var cursor = aMs;
    final spans = [...excluding]..sort((x, y) => x.t0Ms.compareTo(y.t0Ms));
    for (final p in spans) {
      final lo = p.t0Ms > cursor ? p.t0Ms : cursor;
      if (lo > cursor) {
        final m = meanHr(cursor, lo < bMs ? lo : bMs);
        if (m != null) {
          final dt = ((lo < bMs ? lo : bMs) - cursor) / 1000;
          beats += m * dt;
          seconds += dt;
        }
      }
      if (p.t1Ms > cursor) cursor = p.t1Ms;
      if (cursor >= bMs) break;
    }
    if (cursor < bMs) {
      final m = meanHr(cursor, bMs);
      if (m != null) {
        final dt = (bMs - cursor) / 1000;
        beats += m * dt;
        seconds += dt;
      }
    }
    return seconds == 0 ? null : beats / seconds;
  }

  /// Peak HR in `[aMs, bMs)` over samples outside [excluding].
  int? peakHrExcluding(int aMs, int bMs, List<Span> excluding) {
    int? peak;
    for (final s in between(aMs, bMs)) {
      if (s.hr == null) continue;
      if (excluding.any((p) => s.tMs >= p.t0Ms && s.tMs < p.t1Ms)) continue;
      if (peak == null || s.hr! > peak) peak = s.hr;
    }
    return peak;
  }

  /// HR nearest to `tMs` within `toleranceMs`, else null.
  int? hrNear(int tMs, {int toleranceMs = 5000}) {
    final i = indexAtOrBefore(tMs);
    int? best;
    var bestDt = toleranceMs + 1;
    for (var j = i; j >= 0 && j < samples.length; j--) {
      final s = samples[j];
      final dt = (tMs - s.tMs).abs();
      if (dt > toleranceMs) break;
      if (s.hr != null && dt < bestDt) {
        best = s.hr;
        bestDt = dt;
      }
    }
    for (var j = i + 1; j < samples.length; j++) {
      final s = samples[j];
      final dt = (s.tMs - tMs).abs();
      if (dt > toleranceMs) break;
      if (s.hr != null && dt < bestDt) {
        best = s.hr;
        bestDt = dt;
      }
    }
    return best;
  }
}
