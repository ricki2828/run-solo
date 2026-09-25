import '../engine_version.dart';

import 'dart:math' as math;

import '../model/run_file.dart';
import '../model/session_spec.dart';
import '../model/verdict.dart';
import 'constants.dart';
import 'format.dart';
import 'metrics.dart';
import 'rep_detector.dart';

/// What the engine needs to know about an earlier 4x4 to compare against it.
/// The store keeps these in the index; [PriorRun.fromMetrics] builds one from
/// a fresh analysis. Only eligible runs (4x4 after override, not noisy, not
/// indoor, every rep clean) should be passed as priors; the builder also
/// filters by date so a later run can never be a "prior".
class PriorRun {
  const PriorRun({
    required this.id,
    required this.start,
    required this.avgWorkPaceSecPerKm,
    this.fadeSecPerKm,
    this.recoveryPaceSecPerKm,
    this.timeInZoneSeconds,
    this.meanWorkHr,
    this.meanWorkHrFraction,
    this.metresPerBeat,
    this.repPacesSecPerKm = const [],
    this.comparisonKey = ComparisonKey.norwegian4x4,
  });

  final String id;

  /// Only priors of the same key are compared (plan §3.7, D4).
  final String comparisonKey;
  final DateTime start;
  final double avgWorkPaceSecPerKm;
  final double? fadeSecPerKm;
  final double? recoveryPaceSecPerKm;
  final double? timeInZoneSeconds;
  final double? meanWorkHr;
  final double? meanWorkHrFraction;
  final double? metresPerBeat;

  /// Per-rep paces (clean reps; null for an interrupted one) so run 2's
  /// "vs last" column on the detail screen can be filled from the index.
  final List<double?> repPacesSecPerKm;

  /// For the app's summary cache (`index.json`, Phase 3 W5), so a History
  /// load can feed priors without re-analysing every older run.
  Map<String, Object?> toJson() => {
    'id': id,
    'start': start.toUtc().toIso8601String(),
    'avg_work_s_per_km': avgWorkPaceSecPerKm,
    'fade_s_per_km': fadeSecPerKm,
    'recovery_s_per_km': recoveryPaceSecPerKm,
    'time_in_zone_s': timeInZoneSeconds,
    'mean_work_hr': meanWorkHr,
    'mean_work_hr_fraction': meanWorkHrFraction,
    'metres_per_beat': metresPerBeat,
    'rep_paces_s_per_km': repPacesSecPerKm,
    'comparison_key': comparisonKey,
  };

  factory PriorRun.fromJson(Map<String, Object?> j) {
    double? d(String k) => (j[k] as num?)?.toDouble();
    return PriorRun(
      id: j['id']! as String,
      start: DateTime.parse(j['start']! as String).toUtc(),
      avgWorkPaceSecPerKm: d('avg_work_s_per_km')!,
      fadeSecPerKm: d('fade_s_per_km'),
      recoveryPaceSecPerKm: d('recovery_s_per_km'),
      timeInZoneSeconds: d('time_in_zone_s'),
      meanWorkHr: d('mean_work_hr'),
      meanWorkHrFraction: d('mean_work_hr_fraction'),
      metresPerBeat: d('metres_per_beat'),
      repPacesSecPerKm: [
        for (final v in (j['rep_paces_s_per_km'] as List?) ?? const [])
          (v as num?)?.toDouble(),
      ],
      comparisonKey:
          (j['comparison_key'] as String?) ?? ComparisonKey.norwegian4x4,
    );
  }

  static PriorRun? fromMetrics(
    String id,
    DateTime start,
    FourByFourMetrics m, {
    required bool eligible,
    String comparisonKey = ComparisonKey.norwegian4x4,
  }) {
    if (!eligible || m.avgWorkPaceSecPerKm == null) return null;
    return PriorRun(
      id: id,
      start: start,
      avgWorkPaceSecPerKm: m.avgWorkPaceSecPerKm!,
      fadeSecPerKm: m.fadeSecPerKm,
      recoveryPaceSecPerKm: m.recoveryPaceSecPerKm,
      timeInZoneSeconds: m.timeInZoneSeconds,
      meanWorkHr: m.meanWorkHr,
      meanWorkHrFraction: m.meanWorkHrFraction,
      metresPerBeat: m.metresPerBeat,
      repPacesSecPerKm: m.reps
          .map((r) => r.clean ? r.paceSecPerKm : null)
          .toList(),
      comparisonKey: comparisonKey,
    );
  }
}

/// GPS gates and lap state that decide whether a pace verdict is possible.
class VerdictGates {
  const VerdictGates({
    required this.indoor,
    required this.noisy,
    required this.gpsQuality,
  });

  final bool indoor;
  final bool noisy;
  final double gpsQuality;
}

/// Staged verdict + copy pinned to the design brief's verdict copy set.
class VerdictBuilder {
  VerdictBuilder(this.constants);

  final EngineConstants constants;
  String _inputsKey = '';

  /// Noise floor for this run's comparison key (plan §3.7 W1); the 4x4 key
  /// keeps [EngineConstants.runFloorSecPerKm].
  double _floor = EngineConstants.defaults.runFloorSecPerKm;
  double get _run2Floor => _floor * math.sqrt2;

  Verdict build({
    required RunFile run,
    required RepDetection detection,
    required FourByFourMetrics metrics,
    required VerdictGates gates,
    required List<PriorRun> priors,
    required DateTime now,
    String inputsKey = '',
    String comparisonKey = ComparisonKey.norwegian4x4,
    SessionSpec? templateDefault,
  }) {
    _inputsKey = inputsKey;
    _floor = constants.floorSecPerKmForKey(
      comparisonKey,
      templateDefault: templateDefault,
    );
    priors = [
      for (final p in priors)
        if (p.comparisonKey == comparisonKey) p,
    ];
    final floor = _floor;
    final band = constants.repBandSecPerKm;

    Verdict none(VerdictHeadline headline, String subline, {String? hrLine}) =>
        Verdict(
          stage: VerdictStage.none,
          headline: headline,
          subline: subline,
          hrLine: hrLine,
          currentSecPerKm: metrics.avgWorkPaceSecPerKm,
          floorSecPerKm: floor,
          bandSecPerKm: band,
          engineVersion: engineVersion,
          computedAt: now,
          inputsKey: _inputsKey,
        );

    if (gates.indoor) {
      final tiz = metrics.timeInZoneSeconds;
      return none(
        VerdictHeadline.indoorRun,
        tiz == null
            ? 'No pace verdict.'
            : 'No pace verdict. Time in zone ${PaceFormat.mmss(tiz)}.',
      );
    }
    if (!detection.consistent) {
      return none(
        VerdictHeadline.noVerdict,
        'Laps do not match a 4x4. Fix laps to get a verdict.',
      );
    }
    if (gates.noisy) {
      return none(
        VerdictHeadline.noVerdict,
        'GPS too noisy to compare. Reps shown, run not counted.',
      );
    }
    if (metrics.hasInterrupted) {
      final first = metrics.reps.firstWhere((r) => r.interrupted);
      final reason = switch (first.interruptReason!) {
        InterruptReason.gpsDropped => 'GPS dropped',
        InterruptReason.paused => 'Paused',
        InterruptReason.recordingStopped => 'Recording stopped',
      };
      final clean = metrics.cleanRepCount;
      final cleanWord = PaceFormat.countWord(clean);
      final repsWord = clean == 1 ? 'rep is' : 'reps are';
      return none(
        VerdictHeadline.noVerdict,
        '$reason in rep ${first.number}. $cleanWord clean $repsWord not enough '
        'to compare.',
      );
    }

    if (metrics.cleanRepCount < EngineConstants.minReps) {
      // Only reachable through fix-laps `drop`: too few reps left to compare.
      final droppedNumbers = metrics.reps
          .where((r) => r.dropped)
          .map((r) => r.number)
          .join(', ');
      final clean = metrics.cleanRepCount;
      final repsWord = clean == 1 ? 'rep is' : 'reps are';
      return none(
        VerdictHeadline.noVerdict,
        'Rep $droppedNumbers dropped. ${PaceFormat.countWord(clean)} clean '
        '$repsWord not enough to compare.',
      );
    }

    final eligible = priors.where((p) => p.start.isBefore(run.start)).toList()
      ..sort((a, b) => a.start.compareTo(b.start));

    if (eligible.isEmpty) return _baseline(run, metrics, now);
    if (eligible.length == 1) {
      return _vsLast(run, metrics, eligible.single, now);
    }
    return _vsMedian(run, metrics, eligible, now);
  }

  Verdict _baseline(RunFile run, FourByFourMetrics m, DateTime now) {
    final units = run.units;
    final spread = m.repSpreadSecPerKm!;
    final spreadText = spread <= constants.repBandSecPerKm
        ? 'Reps within ${PaceFormat.seconds(PaceFormat.toUnit(spread, units))} of each other.'
        : 'Reps spread ${PaceFormat.seconds(PaceFormat.toUnit(spread, units))}.';
    final recovery = m.recoveryPaceSecPerKm;
    final recoveryText = recovery == null
        ? ''
        : ' Recovery ${PaceFormat.paceBare(recovery, units)}.';
    return Verdict(
      stage: VerdictStage.baseline,
      headline: VerdictHeadline.baselineSet,
      subline:
          '${PaceFormat.pace(m.avgWorkPaceSecPerKm!, units)} work pace. '
          '$spreadText$recoveryText Next 4x4 gets a verdict.',
      hrLine: m.timeInZoneSeconds == null
          ? null
          : 'Time in zone ${PaceFormat.mmss(m.timeInZoneSeconds!)} of '
                '${PaceFormat.mmss(m.workSeconds)}.',
      currentSecPerKm: m.avgWorkPaceSecPerKm,
      floorSecPerKm: _floor,
      bandSecPerKm: constants.repBandSecPerKm,
      engineVersion: engineVersion,
      computedAt: now,
      inputsKey: _inputsKey,
    );
  }

  Verdict _vsLast(
    RunFile run,
    FourByFourMetrics m,
    PriorRun last,
    DateTime now,
  ) {
    final units = run.units;
    final current = m.avgWorkPaceSecPerKm!;
    final baseline = last.avgWorkPaceSecPerKm;
    final delta = baseline - current;
    final floor = _run2Floor;
    final vs =
        '(${PaceFormat.paceBare(current, units)} vs ${PaceFormat.pace(baseline, units)})';
    final VerdictHeadline headline;
    final String subline;
    String? hrLine;
    if (_beyond(delta, floor)) {
      headline = VerdictHeadline.faster;
      subline =
          'Work pace ${PaceFormat.delta(delta, units)} faster than your first 4x4 $vs.'
          '${_fadeSentence(m, last, units)}';
      hrLine = _fasterHrLine(m, last, [last]);
    } else if (_beyond(-delta, floor)) {
      headline = VerdictHeadline.slower;
      subline =
          'Work pace ${PaceFormat.delta(delta, units)} slower than your first 4x4 $vs.'
          '${_fadeSentence(m, last, units)}';
      hrLine = _slowerHrLine(m, last);
    } else {
      headline = VerdictHeadline.noRealChange;
      final lead = delta.round() == 0
          ? 'Same work pace as your first 4x4 (${PaceFormat.pace(current, units)}).'
          : '${PaceFormat.delta(delta, units)} ${delta > 0 ? 'faster' : 'slower'} '
                'than your first 4x4 $vs.';
      subline =
          '$lead Inside what phone GPS can tell (${PaceFormat.delta(floor, units)}).';
    }
    return Verdict(
      stage: VerdictStage.vsLast,
      headline: headline,
      subline: subline,
      hrLine: hrLine,
      currentSecPerKm: current,
      baselineSecPerKm: baseline,
      deltaSecPerKm: delta,
      rank: delta > 0 ? 1 : 0,
      setSize: 1,
      setIds: [last.id],
      floorSecPerKm: floor,
      bandSecPerKm: constants.repBandSecPerKm,
      engineVersion: engineVersion,
      computedAt: now,
      inputsKey: _inputsKey,
    );
  }

  Verdict _vsMedian(
    RunFile run,
    FourByFourMetrics m,
    List<PriorRun> eligible,
    DateTime now,
  ) {
    final units = run.units;
    final current = m.avgWorkPaceSecPerKm!;
    final set = eligible.length > constants.medianSetSize
        ? eligible.sublist(eligible.length - constants.medianSetSize)
        : eligible;
    final baseline = _median(set.map((p) => p.avgWorkPaceSecPerKm).toList());
    final delta = baseline - current;
    final floor = _floor;
    final rank = set.where((p) => p.avgWorkPaceSecPerKm > current).length;
    final last = set.last;
    final vs =
        '(${PaceFormat.paceBare(current, units)} vs ${PaceFormat.pace(baseline, units)})';

    final VerdictHeadline headline;
    final String subline;
    String? hrLine;
    if (_beyond(delta, floor)) {
      headline = VerdictHeadline.faster;
      subline =
          'Work pace ${PaceFormat.delta(delta, units)} faster than your recent 4x4s $vs.'
          '${_fadeSentence(m, last, units)}';
      hrLine = _fasterHrLine(m, last, set);
    } else if (_beyond(-delta, floor)) {
      headline = VerdictHeadline.slower;
      subline =
          'Work pace ${PaceFormat.delta(delta, units)} slower than your recent 4x4s $vs.'
          '${_fadeSentence(m, last, units)}';
      hrLine = _slowerHrLine(m, last);
    } else {
      headline = VerdictHeadline.holding;
      final recovery = m.recoveryPaceSecPerKm;
      final wasRecovery = last.recoveryPaceSecPerKm;
      final recoveryText = recovery == null
          ? ''
          : wasRecovery == null
          ? ' Recovery pace ${PaceFormat.paceBare(recovery, units)}.'
          : ' Recovery pace ${PaceFormat.paceBare(recovery, units)}, was '
                '${PaceFormat.paceBare(wasRecovery, units)}.';
      subline =
          'Within ${PaceFormat.delta(delta, units)} of your recent 4x4s $vs.$recoveryText';
      hrLine = _holdingHrLine(m, last);
    }

    // 365-day best: more than 1% faster than every eligible prior in the window.
    final yearAgo = run.start.subtract(const Duration(days: 365));
    final inYear = eligible.where((p) => !p.start.isBefore(yearAgo)).toList();
    var best = false;
    if (inYear.isNotEmpty) {
      final bestPrior = inYear
          .map((p) => p.avgWorkPaceSecPerKm)
          .reduce((a, b) => a < b ? a : b);
      best = current < bestPrior * (1 - constants.bestBadgeFraction);
    }

    return Verdict(
      stage: VerdictStage.vsMedian,
      headline: headline,
      subline: subline,
      hrLine: hrLine,
      currentSecPerKm: current,
      baselineSecPerKm: baseline,
      deltaSecPerKm: delta,
      rank: rank,
      setSize: set.length,
      setIds: set.map((p) => p.id).toList(),
      floorSecPerKm: floor,
      bandSecPerKm: constants.repBandSecPerKm,
      engineVersion: engineVersion,
      computedAt: now,
      inputsKey: _inputsKey,
      bestIn365Days: best,
      trendSecPerKmPerWeek: theilSenSlope(run.start, current, eligible),
    );
  }

  String _fadeSentence(FourByFourMetrics m, PriorRun last, Units units) {
    final fade = m.fadeSecPerKm;
    if (fade == null) return '';
    final was = last.fadeSecPerKm;
    final fadeText = PaceFormat.seconds(PaceFormat.toUnit(fade, units));
    if (was == null) return ' Fade $fadeText.';
    return ' Fade $fadeText, was ${PaceFormat.seconds(PaceFormat.toUnit(was, units))}.';
  }

  /// The verdict decision uses the displayed (rounded) numbers so "14 s/km
  /// faster" can never sit inside a printed 14 s/km floor.
  static bool _beyond(double delta, double floor) =>
      delta.round() > floor.round();

  /// Plan §5 "faster at the same HR": pace better AND metres-per-beat better
  /// than the baseline (median mpb of the comparison set) → same-HR line;
  /// pace better but mpb worse → "it cost more". Falls back to % max HR
  /// when mpb is unavailable, and to time in zone when no prior has HR.
  String? _fasterHrLine(
    FourByFourMetrics m,
    PriorRun last,
    List<PriorRun> set,
  ) {
    final pct = m.meanWorkHrFraction;
    if (pct == null) return null;
    final was = last.meanWorkHrFraction;
    final pctText = '${(pct * 100).round()}% max HR';
    if (was == null) return _timeInZoneOf(m);
    final wasText = '${(was * 100).round()}%';
    final samePct = ((pct - was) * 100).abs() <= 2;
    final setMpb = set.map((p) => p.metresPerBeat).whereType<double>().toList();
    final mpb = m.metresPerBeat;
    if (mpb != null && setMpb.isNotEmpty) {
      final baselineMpb = _median(setMpb);
      if (mpb >= baselineMpb) {
        return samePct
            ? 'Same effort: $pctText both runs.'
            : 'Faster at the same HR: $pctText, was $wasText.';
      }
      return 'Faster, but it cost more: $pctText, was $wasText.';
    }
    if (samePct) return 'Same effort: $pctText both runs.';
    if (pct > was) return 'Faster, but it cost more: $pctText, was $wasText.';
    return 'Faster at lower effort: $pctText, was $wasText.';
  }

  String? _holdingHrLine(FourByFourMetrics m, PriorRun last) {
    final tiz = m.timeInZoneSeconds;
    if (tiz == null) return null;
    final was = last.timeInZoneSeconds;
    if (was == null) return _timeInZoneOf(m);
    final diff = (tiz - was).round();
    if (diff == 0) {
      return 'Time in zone ${PaceFormat.mmss(tiz)}, same as last time.';
    }
    return 'Time in zone ${PaceFormat.mmss(tiz)}, ${diff > 0 ? 'up' : 'down'} '
        '${PaceFormat.seconds(diff.toDouble())}.';
  }

  String? _slowerHrLine(FourByFourMetrics m, PriorRun last) {
    final hr = m.meanWorkHr;
    if (hr == null) return null;
    final was = last.meanWorkHr;
    if (was != null && was - hr >= 2) {
      return 'HR ${(was - hr).round()} bpm lower: easier day, not a worse one.';
    }
    return _timeInZoneOf(m);
  }

  String? _timeInZoneOf(FourByFourMetrics m) {
    final tiz = m.timeInZoneSeconds;
    if (tiz == null) return null;
    return 'Time in zone ${PaceFormat.mmss(tiz)} of ${PaceFormat.mmss(m.workSeconds)}.';
  }

  static double _median(List<double> values) {
    final sorted = List<double>.from(values)..sort();
    final n = sorted.length;
    return n.isOdd ? sorted[n ~/ 2] : (sorted[n ~/ 2 - 1] + sorted[n ~/ 2]) / 2;
  }

  /// Theil–Sen slope (s/km per week) over the last 12 weeks including the
  /// current run, once there are >= 5 runs spanning >= 4 weeks. Null otherwise.
  static double? theilSenSlope(
    DateTime start,
    double current,
    List<PriorRun> eligible,
  ) {
    final windowStart = start.subtract(const Duration(days: 84));
    final points = <(double, double)>[
      for (final p in eligible)
        if (!p.start.isBefore(windowStart))
          (
            p.start.difference(windowStart).inMinutes / (7 * 24 * 60),
            p.avgWorkPaceSecPerKm,
          ),
      (start.difference(windowStart).inMinutes / (7 * 24 * 60), current),
    ];
    if (points.length < 5) return null;
    final xs = points.map((p) => p.$1).toList()..sort();
    if (xs.last - xs.first < 4) return null;
    final slopes = <double>[];
    for (var i = 0; i < points.length; i++) {
      for (var j = i + 1; j < points.length; j++) {
        final dx = points[j].$1 - points[i].$1;
        if (dx == 0) continue;
        slopes.add((points[j].$2 - points[i].$2) / dx);
      }
    }
    return slopes.isEmpty ? null : _median(slopes);
  }
}
