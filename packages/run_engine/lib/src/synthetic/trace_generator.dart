import 'dart:math' as math;

import '../model/run_file.dart';
import '../model/sidecar.dart';
import '../run_mode.dart';

/// One phase of a synthetic run at a constant true speed.
class Segment {
  const Segment(this.phase, this.seconds, this.speedMps);

  const Segment.warmup(int seconds, double speedMps)
    : this(SegmentPhase.warmup, seconds, speedMps);
  const Segment.work(int seconds, double speedMps)
    : this(SegmentPhase.work, seconds, speedMps);
  const Segment.recovery(int seconds, double speedMps)
    : this(SegmentPhase.recovery, seconds, speedMps);
  const Segment.cooldown(int seconds, double speedMps)
    : this(SegmentPhase.cooldown, seconds, speedMps);
  const Segment.free(int seconds, double speedMps)
    : this(SegmentPhase.free, seconds, speedMps);

  final SegmentPhase phase;
  final int seconds;
  final double speedMps;

  int get ms => seconds * 1000;

  /// s/km at this speed: the analytic pace the engine must recover.
  double get paceSecPerKm => 1000 / speedMps;
}

enum SegmentPhase { warmup, work, recovery, cooldown, free }

/// How lap boundaries are recorded between segments.
enum LapStyle {
  /// No laps at all (free run, or a 4x4 that must fall back to speed).
  none,

  /// A cue-driven auto-lap exactly at each work/recovery boundary.
  auto,

  /// A LAP press `manualDelayMs` after each boundary.
  manual,
}

/// Everything that shapes a synthetic trace. Ground truth is the segment
/// list; every distortion is explicit and seeded so fixtures are reproducible.
class SyntheticSpec {
  const SyntheticSpec({
    required this.name,
    required this.segments,
    this.id = '00000000-0000-4000-8000-000000000001',
    this.mode = RunMode.fourByFour,
    this.preset,
    this.units = Units.km,
    this.lapStyle = LapStyle.auto,
    this.manualDelayMs = 1000,
    this.missedBoundaries = const {},
    this.gpsLagMs = 3000,
    this.jitterSigmaM = 0,
    this.jitterCorrelation = 0.99,
    this.accuracyM = 6,
    this.badAccuracyShare = 0,
    this.dropouts = const [],
    this.pauses = const [],
    this.moveWhilePausedMps = 0,
    this.samplesDuringPause = false,
    this.gaps = const [],
    this.hr = false,
    this.hrStep = false,
    this.indoor = false,
    this.seed = 1,
    this.start,
    this.expectLapsConsistent,
    this.toleranceSecPerKm,
  });

  final String name;
  final List<Segment> segments;
  final String id;
  final RunMode mode;
  final Preset? preset;
  final Units units;
  final LapStyle lapStyle;
  final int manualDelayMs;

  /// 0-based indices into the segment boundaries (boundary `k` is the end of
  /// segment `k`) where the runner forgot to press LAP.
  final Set<int> missedBoundaries;

  /// Observed position lags the true position by this much (GPS lag).
  final int gpsLagMs;

  /// Std dev (m, per axis) of the AR(1) position jitter; 0 = clean.
  final double jitterSigmaM;
  final double jitterCorrelation;

  /// Reported accuracy for good samples.
  final double accuracyM;

  /// Share of samples reported with accuracy 40 m (rejected by the recorder).
  final double badAccuracyShare;

  /// Spans (ms) with no samples at all, e.g. a tunnel.
  final List<Span> dropouts;

  /// Spans (ms) the runner paused; written to `pauses[]`. By default a
  /// standstill with no samples.
  final List<Span> pauses;

  /// Ground covered per second while paused (walking across a road).
  final double moveWhilePausedMps;

  /// Emit samples during pauses with `dist` still accumulating: the shape
  /// of a writer that does not freeze distance while paused.
  final bool samplesDuringPause;

  /// Spans (ms) the process was dead; no samples, written to `gaps[]`.
  final List<Span> gaps;
  final bool hr;

  /// HR jumps to the phase target instantly with no noise, so mean/peak HR,
  /// time in zone and m/beat have exact analytic values.
  final bool hrStep;

  /// Treadmill: no fixes, no distance, HR only.
  final bool indoor;
  final int seed;
  final DateTime? start;

  /// Overrides the derived expectation for specs whose segments break the
  /// pattern on purpose (e.g. a work phase cut short).
  final bool? expectLapsConsistent;

  /// Overrides the derived tolerance (speed-stream fallback is coarser).
  final double? toleranceSecPerKm;

  int get totalMs => segments.fold(0, (s, seg) => s + seg.ms);
}

/// The analytic answer for a spec, computed from the segments, never from the
/// engine (plan §5 W5).
class SyntheticExpectation {
  const SyntheticExpectation({
    required this.repCount,
    required this.repPacesSecPerKm,
    required this.avgWorkPaceSecPerKm,
    required this.recoveryPaceSecPerKm,
    required this.fadeSecPerKm,
    required this.spreadSecPerKm,
    required this.lapsConsistent,
    required this.interruptedReps,
    required this.toleranceSecPerKm,
    required this.recoveryToleranceSecPerKm,
    required this.indoor,
    required this.noisy,
    required this.rescueEdits,
    required this.headlineRun1,
    this.expectedMeanWorkHr,
    this.expectedZoneSecondsAtMax180,
    this.expectedMetresPerBeat,
  });

  final int repCount;
  final List<double> repPacesSecPerKm;
  final double? avgWorkPaceSecPerKm;
  final double? recoveryPaceSecPerKm;
  final double? fadeSecPerKm;
  final double? spreadSecPerKm;
  final bool lapsConsistent;

  /// 1-based rep numbers the engine must mark interrupted.
  final List<int> interruptedReps;

  /// How close the engine must land (0.5 for clean traces, wider with jitter).
  final double toleranceSecPerKm;

  /// Recovery pace tolerance. Jitter inflates distance more at slow speed
  /// (relative inflation grows with σ²/v), so it is wider than the work one.
  final double recoveryToleranceSecPerKm;
  final bool indoor;
  final bool noisy;

  /// Fix-laps edits that turn an inconsistent recording back into the 4x4.
  final List<LapEdit> rescueEdits;

  /// Headline key expected when this run is analysed with no priors.
  final String headlineRun1;

  /// HR truth, only for `hrStep` specs (see the generator).
  final double? expectedMeanWorkHr;
  final double? expectedZoneSecondsAtMax180;
  final double? expectedMetresPerBeat;

  Map<String, Object?> toJson() => {
    'rep_count': repCount,
    'rep_paces_s_per_km': repPacesSecPerKm,
    'avg_work_pace_s_per_km': avgWorkPaceSecPerKm,
    'recovery_pace_s_per_km': recoveryPaceSecPerKm,
    'fade_s_per_km': fadeSecPerKm,
    'spread_s_per_km': spreadSecPerKm,
    'laps_consistent': lapsConsistent,
    'interrupted_reps': interruptedReps,
    'tolerance_s_per_km': toleranceSecPerKm,
    'recovery_tolerance_s_per_km': recoveryToleranceSecPerKm,
    'indoor': indoor,
    'noisy': noisy,
    'rescue_edits': rescueEdits.map((e) => e.toJson()).toList(),
    'headline_run1': headlineRun1,
    'expected_mean_work_hr': expectedMeanWorkHr,
    'expected_zone_seconds_at_max_180': expectedZoneSecondsAtMax180,
    'expected_metres_per_beat': expectedMetresPerBeat,
  };

  factory SyntheticExpectation.fromJson(
    Map<String, Object?> json,
  ) => SyntheticExpectation(
    repCount: json['rep_count'] as int,
    repPacesSecPerKm: (json['rep_paces_s_per_km'] as List)
        .map((e) => (e as num).toDouble())
        .toList(),
    avgWorkPaceSecPerKm: (json['avg_work_pace_s_per_km'] as num?)?.toDouble(),
    recoveryPaceSecPerKm: (json['recovery_pace_s_per_km'] as num?)?.toDouble(),
    fadeSecPerKm: (json['fade_s_per_km'] as num?)?.toDouble(),
    spreadSecPerKm: (json['spread_s_per_km'] as num?)?.toDouble(),
    lapsConsistent: json['laps_consistent'] as bool,
    interruptedReps: (json['interrupted_reps'] as List).cast<int>(),
    toleranceSecPerKm: (json['tolerance_s_per_km'] as num).toDouble(),
    recoveryToleranceSecPerKm: (json['recovery_tolerance_s_per_km'] as num)
        .toDouble(),
    indoor: json['indoor'] as bool,
    noisy: json['noisy'] as bool,
    rescueEdits: (json['rescue_edits'] as List)
        .map((e) => LapEdit.fromJson(e as Map<String, Object?>))
        .toList(),
    headlineRun1: json['headline_run1'] as String,
    expectedMeanWorkHr: (json['expected_mean_work_hr'] as num?)?.toDouble(),
    expectedZoneSecondsAtMax180:
        (json['expected_zone_seconds_at_max_180'] as num?)?.toDouble(),
    expectedMetresPerBeat: (json['expected_metres_per_beat'] as num?)
        ?.toDouble(),
  );
}

class SyntheticRun {
  const SyntheticRun(this.spec, this.run, this.expected);
  final SyntheticSpec spec;
  final RunFile run;
  final SyntheticExpectation expected;
}

/// Emits a 1 Hz trace with known rep speeds plus injected GPS lag, jitter,
/// gaps and accuracy spikes, so expected paces are computed, not pinned from
/// the engine's own output (plan §5).
class TraceGenerator {
  const TraceGenerator({
    this.trimStartMs = 12000,
    this.trimEndMs = 5000,
    this.accuracyRejectM = 25,
  });

  /// Mirrors the engine's rep-edge trim so the analytic average is weighted
  /// the same way the engine weights it.
  final int trimStartMs;
  final int trimEndMs;

  /// Mirrors the recorder's accept rule (plan §3).
  final double accuracyRejectM;

  static const double _lat0 = -33.86;
  static const double _lon0 = 151.21;

  SyntheticRun generate(SyntheticSpec spec) {
    final rng = math.Random(spec.seed);
    final totalMs = spec.totalMs;
    final start = spec.start ?? DateTime.utc(2026, 9, 24, 6, 0);

    // Boundaries between segments, in ms.
    final boundaries = <int>[];
    var acc = 0;
    for (var i = 0; i < spec.segments.length - 1; i++) {
      acc += spec.segments[i].ms;
      boundaries.add(acc);
    }

    // True cumulative distance at t (piecewise linear).
    // A pause is a standstill: the runner covers no ground while paused,
    // so true distance advances with moving time only. Dropouts and
    // kill→resume gaps keep the runner moving (the phone lost the signal).
    int pausedBefore(int tMs) {
      var total = 0;
      for (final p in spec.pauses) {
        if (tMs <= p.t0Ms) continue;
        total += (tMs < p.t1Ms ? tMs : p.t1Ms) - p.t0Ms;
      }
      return total;
    }

    double trueDist(int tMs) {
      var d = 0.0;
      var t = 0;
      for (final seg in spec.segments) {
        final segEnd = t + seg.ms;
        final upto = tMs < segEnd ? tMs : segEnd;
        if (upto > t) {
          final paused = pausedBefore(upto) - pausedBefore(t);
          final moving = (upto - t) - paused;
          d += seg.speedMps * moving / 1000;
          d += spec.moveWhilePausedMps * paused / 1000;
        }
        if (tMs <= segEnd) return d;
        t = segEnd;
      }
      return d;
    }

    bool silent(int tMs) =>
        spec.dropouts.any((s) => tMs >= s.t0Ms && tMs < s.t1Ms) ||
        (!spec.samplesDuringPause &&
            spec.pauses.any((s) => tMs >= s.t0Ms && tMs < s.t1Ms)) ||
        spec.gaps.any((s) => tMs >= s.t0Ms && tMs < s.t1Ms);

    final samples = <Sample>[];
    var jitterX = 0.0;
    var jitterY = 0.0;
    var dist = 0.0;
    double? lastLat;
    double? lastLon;
    var hr = 120.0;
    // Same sphere as the recorder's haversine (R = 6371 km) so a clean trace
    // reproduces the analytic pace exactly.
    const mPerDegLat = 6371000.0 * math.pi / 180;
    final mPerDegLon = mPerDegLat * math.cos(_lat0 * math.pi / 180);

    for (var t = 0; t <= totalMs; t += 1000) {
      // HR follows the phase target with a 30 s time constant.
      final target = _hrTarget(_phaseAt(spec, t));
      hr = spec.hrStep ? target : target + (hr - target) * math.exp(-1 / 30);
      final hrNoisy = spec.hrStep
          ? hr.round()
          : (hr + (rng.nextDouble() * 4 - 2)).round();

      if (silent(t)) continue;

      if (spec.indoor) {
        samples.add(Sample(tMs: t, distM: 0, hr: spec.hr ? hrNoisy : null));
        continue;
      }

      final observedT = math.max(0, t - spec.gpsLagMs);
      final trueD = trueDist(observedT);
      jitterX =
          spec.jitterCorrelation * jitterX +
          _gauss(rng) *
              spec.jitterSigmaM *
              math.sqrt(1 - spec.jitterCorrelation * spec.jitterCorrelation);
      jitterY =
          spec.jitterCorrelation * jitterY +
          _gauss(rng) *
              spec.jitterSigmaM *
              math.sqrt(1 - spec.jitterCorrelation * spec.jitterCorrelation);
      final lat = _lat0 + jitterY / mPerDegLat;
      final lon = _lon0 + (trueD + jitterX) / mPerDegLon;
      final bad =
          spec.badAccuracyShare > 0 && rng.nextDouble() < spec.badAccuracyShare;
      final accuracy = bad ? 40.0 : spec.accuracyM;

      // Recorder rule: accept if accuracy <= 25 m; distance = haversine over
      // accepted points. Rejected samples are still journaled.
      if (accuracy <= accuracyRejectM) {
        if (lastLat != null) {
          dist += _haversine(lastLat, lastLon!, lat, lon);
        }
        lastLat = lat;
        lastLon = lon;
      }
      final segSpeed = _speedAt(spec, observedT);
      samples.add(
        Sample(
          tMs: t,
          lat: lat,
          lon: lon,
          altM: 20,
          accM: accuracy,
          speedMps: segSpeed,
          distM: dist,
          hr: spec.hr ? hrNoisy : null,
        ),
      );
    }

    // Laps: one per kept boundary, covering the whole run.
    final laps = <Lap>[];
    if (spec.lapStyle != LapStyle.none) {
      final pressTimes = <int>[];
      for (var k = 0; k < boundaries.length; k++) {
        if (spec.missedBoundaries.contains(k)) continue;
        final delay = spec.lapStyle == LapStyle.manual ? spec.manualDelayMs : 0;
        pressTimes.add(boundaries[k] + delay);
      }
      final kind = spec.lapStyle == LapStyle.manual
          ? LapKind.manual
          : LapKind.auto;
      final edges = [0, ...pressTimes, totalMs];
      final sampleDist = _Interp(samples);
      for (var i = 0; i + 1 < edges.length; i++) {
        laps.add(
          Lap(
            index: i,
            t0Ms: edges[i],
            t1Ms: edges[i + 1],
            d0M: sampleDist.at(edges[i]),
            d1M: sampleDist.at(edges[i + 1]),
            kind: kind,
          ),
        );
      }
    }

    final run = RunFile(
      id: spec.id,
      device: 'synthetic',
      app: 'run_engine generator',
      start: start,
      end: start.add(Duration(milliseconds: totalMs)),
      tz: 'Australia/Sydney',
      mode: spec.mode,
      preset: spec.preset,
      units: spec.units,
      laps: laps,
      pauses: spec.pauses,
      gaps: spec.gaps,
      samples: samples,
    );

    return SyntheticRun(spec, run, _expect(spec, boundaries));
  }

  SyntheticExpectation _expect(SyntheticSpec spec, List<int> boundaries) {
    final works = <Segment>[];
    final recoveries = <Segment>[];
    for (final seg in spec.segments) {
      if (seg.phase == SegmentPhase.work) works.add(seg);
      if (seg.phase == SegmentPhase.recovery) recoveries.add(seg);
    }
    // Trimmed moving seconds per segment: the engine's window minus any
    // paused time inside it (a pause is a standstill, excluded from pace).
    final segStart = <int, int>{};
    var acc = 0;
    for (var i = 0; i < spec.segments.length; i++) {
      segStart[i] = acc;
      acc += spec.segments[i].ms;
    }
    int indexOf(Segment seg) => spec.segments.indexOf(seg);
    double trimmedMoving(Segment seg) {
      final a = segStart[indexOf(seg)]! + trimStartMs;
      final b = segStart[indexOf(seg)]! + seg.ms - trimEndMs;
      var paused = 0;
      for (final p in spec.pauses) {
        final lo = p.t0Ms > a ? p.t0Ms : a;
        final hi = p.t1Ms < b ? p.t1Ms : b;
        if (hi > lo) paused += hi - lo;
      }
      return (b - a - paused) / 1000;
    }

    double? weighted(List<Segment> segs) {
      if (segs.isEmpty) return null;
      var secs = 0.0;
      var dist = 0.0;
      for (final s in segs) {
        final w = trimmedMoving(s);
        secs += w;
        dist += s.speedMps * w;
      }
      return secs / dist * 1000;
    }

    // HR truth (step profile only): every work sample sits at the work
    // target, so mean = peak = target and zone time = the rep's sampled
    // seconds when the target is inside 85–95% of max HR 180 (153–171).
    double? expectedMeanWorkHr;
    double? expectedZoneSeconds;
    double? expectedMpb;
    if (spec.hr && spec.hrStep) {
      final target = _hrTarget(SegmentPhase.work);
      expectedMeanWorkHr = target;
      final inZone = target >= 180 * 0.85 && target <= 180 * 0.95;
      var workSecs = 0.0;
      for (final w in works) {
        var silent = 0;
        final a = segStart[indexOf(w)]!;
        final b = a + w.ms;
        for (final sp in [...spec.pauses, ...spec.dropouts, ...spec.gaps]) {
          final lo = sp.t0Ms > a ? sp.t0Ms : a;
          final hi = sp.t1Ms < b ? sp.t1Ms : b;
          if (hi > lo) silent += hi - lo;
        }
        workSecs += (w.ms - silent) / 1000;
      }
      expectedZoneSeconds = inZone ? workSecs : 0;
      var dist = 0.0;
      var beats = 0.0;
      for (final w in works) {
        final sec = trimmedMoving(w);
        dist += w.speedMps * sec;
        beats += target * sec / 60;
      }
      expectedMpb = beats == 0 ? null : dist / beats;
    }

    final repPaces = works.map((w) => w.paceSecPerKm).toList();
    double? spread;
    double? fade;
    if (repPaces.isNotEmpty) {
      spread = repPaces.reduce(math.max) - repPaces.reduce(math.min);
      fade = repPaces.last - repPaces.first;
    }

    // Which reps are interrupted: any silent span or gap inside a work segment.
    final interrupted = <int>[];
    var t = 0;
    var repNo = 0;
    for (final seg in spec.segments) {
      final t0 = t;
      final t1 = t + seg.ms;
      if (seg.phase == SegmentPhase.work) {
        repNo++;
        final hit =
            spec.gaps.any((s) => s.overlaps(t0, t1)) ||
            spec.pauses.any(
              (s) => s.overlaps(t0, t1) && s.durationMs > 20000,
            ) ||
            spec.dropouts.any(
              (s) => s.overlaps(t0, t1) && s.durationMs > 10000,
            );
        if (hit) interrupted.add(repNo);
      }
      t = t1;
    }

    // Rescue edits: split the lap that swallowed each missed boundary.
    final rescue = <LapEdit>[];
    final kept = [
      for (var k = 0; k < boundaries.length; k++)
        if (!spec.missedBoundaries.contains(k)) boundaries[k],
    ];
    final missedSorted = spec.missedBoundaries.toList()..sort();
    var inserted = 0;
    for (final k in missedSorted) {
      final tb = boundaries[k];
      final lapIndex = kept.where((b) => b < tb).length + inserted;
      final delay = spec.lapStyle == LapStyle.manual ? spec.manualDelayMs : 0;
      rescue.add(LapEdit.split(lapIndex, tb + delay));
      inserted++;
    }

    final noisy = !spec.indoor && spec.badAccuracyShare > 0.2;
    final consistent =
        spec.expectLapsConsistent ??
        (spec.mode == RunMode.fourByFour &&
            spec.missedBoundaries.isEmpty &&
            works.length >= 3 &&
            works.length <= 6);
    final String headline;
    if (spec.mode != RunMode.fourByFour) {
      headline = 'none';
    } else if (spec.indoor) {
      headline = 'indoorRun';
    } else if (!consistent || noisy || interrupted.isNotEmpty) {
      headline = 'noVerdict';
    } else {
      headline = 'baselineSet';
    }

    final tolerance =
        spec.toleranceSecPerKm ?? (spec.jitterSigmaM == 0 ? 0.5 : 3);
    return SyntheticExpectation(
      repCount: works.length,
      repPacesSecPerKm: repPaces,
      avgWorkPaceSecPerKm: spec.indoor ? null : weighted(works),
      recoveryPaceSecPerKm: spec.indoor ? null : weighted(recoveries),
      fadeSecPerKm: fade,
      spreadSecPerKm: spread,
      lapsConsistent: consistent,
      interruptedReps: interrupted,
      toleranceSecPerKm: tolerance,
      recoveryToleranceSecPerKm: spec.jitterSigmaM == 0
          ? tolerance
          : tolerance * 2,
      indoor: spec.indoor,
      noisy: noisy,
      rescueEdits: rescue,
      headlineRun1: headline,
      expectedMeanWorkHr: expectedMeanWorkHr,
      expectedZoneSecondsAtMax180: expectedZoneSeconds,
      expectedMetresPerBeat: expectedMpb,
    );
  }

  static SegmentPhase _phaseAt(SyntheticSpec spec, int tMs) {
    var t = 0;
    for (final seg in spec.segments) {
      if (tMs < t + seg.ms) return seg.phase;
      t += seg.ms;
    }
    return spec.segments.last.phase;
  }

  static double _speedAt(SyntheticSpec spec, int tMs) {
    var t = 0;
    for (final seg in spec.segments) {
      if (tMs < t + seg.ms) return seg.speedMps;
      t += seg.ms;
    }
    return spec.segments.last.speedMps;
  }

  static double _hrTarget(SegmentPhase phase) => switch (phase) {
    SegmentPhase.warmup => 135,
    SegmentPhase.work => 168,
    SegmentPhase.recovery => 148,
    SegmentPhase.cooldown => 128,
    SegmentPhase.free => 142,
  };

  static double _gauss(math.Random rng) {
    // Box–Muller.
    final u1 = 1 - rng.nextDouble();
    final u2 = rng.nextDouble();
    return math.sqrt(-2 * math.log(u1)) * math.cos(2 * math.pi * u2);
  }

  static double _haversine(double lat1, double lon1, double lat2, double lon2) {
    const r = 6371000.0;
    final p1 = lat1 * math.pi / 180;
    final p2 = lat2 * math.pi / 180;
    final dp = (lat2 - lat1) * math.pi / 180;
    final dl = (lon2 - lon1) * math.pi / 180;
    final a =
        math.sin(dp / 2) * math.sin(dp / 2) +
        math.cos(p1) * math.cos(p2) * math.sin(dl / 2) * math.sin(dl / 2);
    return 2 * r * math.atan2(math.sqrt(a), math.sqrt(1 - a));
  }
}

class _Interp {
  _Interp(this.samples);
  final List<Sample> samples;

  double at(int tMs) {
    if (samples.isEmpty) return 0;
    if (tMs <= samples.first.tMs) return samples.first.distM;
    if (tMs >= samples.last.tMs) return samples.last.distM;
    var lo = 0;
    var hi = samples.length - 1;
    while (lo < hi - 1) {
      final mid = (lo + hi) >> 1;
      if (samples[mid].tMs <= tMs) {
        lo = mid;
      } else {
        hi = mid;
      }
    }
    final a = samples[lo];
    final b = samples[hi];
    final f = (tMs - a.tMs) / (b.tMs - a.tMs);
    return a.distM + (b.distM - a.distM) * f;
  }
}

/// The fixture set (plan §5, §12): every case the Dart unit list names.
class SyntheticSpecs {
  const SyntheticSpecs._();

  static const double _work = 1000 / 284; // 4:44/km
  static const double _rec = 1000 / 370; // 6:10/km
  static const double _easy = 1000 / 360; // 6:00/km
  static const double _warm = 1000 / 390; // 6:30/km

  static List<Segment> fourByFour({
    int reps = 4,
    int workS = 240,
    int recoveryS = 180,
    List<double>? workSpeeds,
    double recoverySpeed = _rec,
    int warmupS = 480,
    int cooldownS = 300,
  }) => [
    Segment.warmup(warmupS, _warm),
    for (var i = 0; i < reps; i++) ...[
      Segment.work(workS, workSpeeds?[i] ?? _work),
      Segment.recovery(recoveryS, recoverySpeed),
    ],
    Segment.cooldown(cooldownS, _warm),
  ];

  static String _id(int n) =>
      '00000000-0000-4000-8000-${n.toString().padLeft(12, '0')}';

  static final List<SyntheticSpec> all = [
    SyntheticSpec(
      name: 'easy_free_run',
      id: _id(1),
      mode: RunMode.free,
      lapStyle: LapStyle.none,
      segments: const [Segment.free(1800, _easy)],
      hr: true,
    ),
    SyntheticSpec(
      name: 'four_by_four_manual_clean',
      id: _id(2),
      lapStyle: LapStyle.manual,
      segments: fourByFour(
        workSpeeds: const [1000 / 282, 1000 / 283, 1000 / 285, 1000 / 288],
      ),
    ),
    SyntheticSpec(
      // §18.2: the same by-feel 4x4 shape recorded as a Laps run. The lap
      // table lists every press; a sidecar override to 4x4 must reproduce
      // the by-feel verdict of `four_by_four_manual_clean_hr` exactly.
      name: 'laps_run_manual_clean_hr',
      id: _id(35),
      mode: RunMode.laps,
      lapStyle: LapStyle.manual,
      hr: true,
      segments: fourByFour(
        workSpeeds: const [1000 / 282, 1000 / 283, 1000 / 285, 1000 / 288],
      ),
    ),
    SyntheticSpec(
      name: 'four_by_four_manual_clean_hr',
      id: _id(3),
      lapStyle: LapStyle.manual,
      hr: true,
      segments: fourByFour(
        workSpeeds: const [1000 / 282, 1000 / 283, 1000 / 285, 1000 / 288],
      ),
    ),
    SyntheticSpec(
      name: 'four_by_four_missed_press',
      id: _id(4),
      lapStyle: LapStyle.manual,
      // Boundary 4 = end of rep 2's work segment (warmup=0, w1=1, r1=2, w2=3).
      missedBoundaries: const {3},
      segments: fourByFour(),
    ),
    SyntheticSpec(
      name: 'preset_4x4_auto_standard',
      id: _id(5),
      preset: Preset.standard,
      segments: fourByFour(),
    ),
    SyntheticSpec(
      name: 'preset_4x4_manual_standard',
      id: _id(6),
      preset: Preset.standard,
      lapStyle: LapStyle.manual,
      manualDelayMs: 0,
      segments: fourByFour(),
    ),
    SyntheticSpec(
      name: 'preset_3x4_recovery_2_00',
      id: _id(7),
      preset: const Preset(reps: 3, workSeconds: 240, recoverySeconds: 120),
      segments: fourByFour(reps: 3, recoveryS: 120),
    ),
    SyntheticSpec(
      name: 'preset_4x4_recovery_3_30',
      id: _id(8),
      preset: const Preset(reps: 4, workSeconds: 240, recoverySeconds: 210),
      segments: fourByFour(recoveryS: 210),
    ),
    SyntheticSpec(
      name: 'preset_6x4_recovery_5_00',
      id: _id(9),
      preset: const Preset(reps: 6, workSeconds: 240, recoverySeconds: 300),
      segments: fourByFour(reps: 6, recoveryS: 300),
    ),
    SyntheticSpec(
      name: 'preset_5x4_recovery_2_00_missing_final_recovery',
      id: _id(10),
      preset: const Preset(reps: 5, workSeconds: 240, recoverySeconds: 120),
      segments: [
        const Segment.warmup(480, _warm),
        for (var i = 0; i < 4; i++) ...[
          const Segment.work(240, _work),
          const Segment.recovery(120, _rec),
        ],
        const Segment.work(240, _work),
        const Segment.cooldown(300, _warm),
      ],
    ),
    SyntheticSpec(
      name: 'gps_dropout_rep2',
      id: _id(11),
      preset: Preset.standard,
      // Rep 2 work runs 900–1140 s; 40 s of silence inside it.
      dropouts: const [Span(960000, 1000000)],
      segments: fourByFour(),
    ),
    SyntheticSpec(
      name: 'pause_mid_rep3',
      id: _id(12),
      preset: Preset.standard,
      // Rep 3 work runs 1320–1560 s; a 30 s pause inside it.
      pauses: const [Span(1400000, 1430000)],
      segments: fourByFour(),
    ),
    SyntheticSpec(
      name: 'kill_resume_gap_rep2',
      id: _id(13),
      preset: Preset.standard,
      gaps: const [Span(1000000, 1090000)],
      segments: fourByFour(),
    ),
    SyntheticSpec(
      name: 'noisy_gps_phone_jitter',
      id: _id(14),
      preset: Preset.standard,
      jitterSigmaM: 2,
      accuracyM: 12,
      badAccuracyShare: 0.05,
      hr: true,
      segments: fourByFour(),
    ),
    SyntheticSpec(
      name: 'very_noisy_gps_no_verdict',
      id: _id(15),
      preset: Preset.standard,
      jitterSigmaM: 8,
      accuracyM: 18,
      badAccuracyShare: 0.35,
      segments: fourByFour(),
    ),
    SyntheticSpec(
      name: 'treadmill_indoor',
      id: _id(16),
      preset: Preset.standard,
      indoor: true,
      hr: true,
      segments: fourByFour(),
    ),
    SyntheticSpec(
      name: 'four_by_four_no_laps_speed_fallback',
      id: _id(17),
      lapStyle: LapStyle.none,
      toleranceSecPerKm: 6,
      segments: fourByFour(),
    ),
    SyntheticSpec(
      name: 'preset_work_cut_short_inconsistent',
      id: _id(18),
      preset: Preset.standard,
      expectLapsConsistent: false,
      segments: [
        const Segment.warmup(480, _warm),
        const Segment.work(240, _work),
        const Segment.recovery(180, _rec),
        const Segment.work(200, _work), // 3:20, beyond the ±30 s tolerance
        const Segment.recovery(180, _rec),
        const Segment.work(240, _work),
        const Segment.recovery(180, _rec),
        const Segment.work(240, _work),
        const Segment.recovery(180, _rec),
        const Segment.cooldown(300, _warm),
      ],
    ),

    // --- §6 edge phases: a cut/long phase on the edge of the block must be
    // flagged, never relabelled warm-up or cool-down (review P1-1).
    SyntheticSpec(
      name: 'preset_rep1_cut_short',
      id: _id(19),
      preset: Preset.standard,
      expectLapsConsistent: false,
      segments: _withWork(0, 200),
    ),
    SyntheticSpec(
      name: 'preset_last_rep_cut_short',
      id: _id(20),
      preset: Preset.standard,
      expectLapsConsistent: false,
      segments: _withWork(3, 200),
    ),
    SyntheticSpec(
      name: 'preset_recovery1_cut_short',
      id: _id(21),
      preset: Preset.standard,
      expectLapsConsistent: false,
      segments: _withRecovery(0, 140),
    ),
    // --- preset ±30 s edges (B5): 4:30 / 3:30 accepted, 4:31 / 3:29 flagged.
    SyntheticSpec(
      name: 'preset_work_4_30_accepted',
      id: _id(22),
      preset: Preset.standard,
      segments: _withWork(3, 270),
    ),
    SyntheticSpec(
      name: 'preset_work_4_31_flagged',
      id: _id(23),
      preset: Preset.standard,
      expectLapsConsistent: false,
      segments: _withWork(0, 271),
    ),
    SyntheticSpec(
      name: 'preset_work_3_30_accepted',
      id: _id(24),
      preset: Preset.standard,
      segments: _withWork(0, 210),
    ),
    SyntheticSpec(
      name: 'preset_work_3_29_flagged',
      id: _id(25),
      preset: Preset.standard,
      expectLapsConsistent: false,
      segments: _withWork(1, 209),
    ),
    SyntheticSpec(
      name: 'preset_recovery_edges_accepted',
      id: _id(26),
      preset: Preset.standard,
      segments: _withRecovery(2, 210, also: const {0: 150}),
    ),
    SyntheticSpec(
      name: 'preset_recovery_3_31_flagged',
      id: _id(27),
      preset: Preset.standard,
      expectLapsConsistent: false,
      segments: _withRecovery(2, 211),
    ),
    // --- short pauses inside a rep (review P1-2): pace excludes the
    // standstill; a genuine pause is never "GPS dropped".
    SyntheticSpec(
      name: 'pause_8s_in_rep3',
      id: _id(28),
      preset: Preset.standard,
      pauses: const [Span(1400000, 1408000)],
      segments: fourByFour(),
    ),
    SyntheticSpec(
      name: 'pause_15s_in_rep3',
      id: _id(29),
      preset: Preset.standard,
      pauses: const [Span(1400000, 1415000)],
      segments: fourByFour(),
    ),
    // --- GPS lag equal to the trim: exact only because the trim exists.
    SyntheticSpec(
      name: 'gps_lag_12s',
      id: _id(30),
      preset: Preset.standard,
      gpsLagMs: 12000,
      segments: fourByFour(),
    ),
    // --- review round 3: warm-up / truncated final recovery are never
    // phases (P2-13); ground covered while paused is excluded (P2-14).
    SyntheticSpec(
      name: 'warmup_2_15_clean',
      id: _id(32),
      preset: Preset.standard,
      segments: fourByFour(warmupS: 135),
    ),
    SyntheticSpec(
      name: 'final_recovery_truncated_2_20',
      id: _id(33),
      preset: Preset.standard,
      segments: [
        ...fourByFour(cooldownS: 0).sublist(0, 8),
        const Segment.recovery(140, _rec),
      ],
    ),
    SyntheticSpec(
      name: 'pause_moved_while_paused',
      id: _id(34),
      preset: Preset.standard,
      pauses: const [Span(1400000, 1420000)],
      moveWhilePausedMps: 1.2,
      samplesDuringPause: true,
      // GPS lag puts ~3 s of pre-pause running inside the pause span, which
      // this writer shape cannot separate from the walking; 5 s/km covers it.
      toleranceSecPerKm: 5,
      segments: fourByFour(),
    ),
    // --- HR step profile with analytic zone time and m/beat.
    SyntheticSpec(
      name: 'preset_4x4_hr_step',
      id: _id(31),
      preset: Preset.standard,
      hr: true,
      hrStep: true,
      segments: fourByFour(),
    ),
  ];

  /// The standard 4x4 with work segment [rep] (0-based) set to [seconds].
  static List<Segment> _withWork(int rep, int seconds) {
    final segs = fourByFour();
    final i = 1 + rep * 2;
    segs[i] = Segment.work(seconds, segs[i].speedMps);
    return segs;
  }

  /// The standard 4x4 with recovery [rep] (0-based) set to [seconds], plus
  /// any other recoveries in [also].
  static List<Segment> _withRecovery(
    int rep,
    int seconds, {
    Map<int, int> also = const {},
  }) {
    final segs = fourByFour();
    for (final e in {rep: seconds, ...also}.entries) {
      final i = 2 + e.key * 2;
      segs[i] = Segment.recovery(e.value, segs[i].speedMps);
    }
    return segs;
  }
}
