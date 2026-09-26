import '../engine_version.dart';

import 'dart:math' as math;

import '../model/run_file.dart';
import '../model/session_spec.dart';
import '../model/verdict.dart';
import 'constants.dart';
import 'event_names.dart';
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
    this.repCount,
    this.recoveryLabel,
  });

  final String id;

  /// Only priors of the same key are compared (plan §3.7, D4).
  final String comparisonKey;

  /// Planned reps and the recovery ("2:30 recovery", "200 m jog") of the
  /// session, for the D4 note when they differ from this run's; null for a
  /// by-feel 4x4 (count = detected reps, no planned recovery).
  final int? repCount;
  final String? recoveryLabel;
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
    'rep_count': repCount,
    'recovery_label': recoveryLabel,
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
      repCount: j['rep_count'] as int?,
      recoveryLabel: j['recovery_label'] as String?,
    );
  }

  static PriorRun? fromMetrics(
    String id,
    DateTime start,
    IntervalMetrics m, {
    required bool eligible,
    String comparisonKey = ComparisonKey.norwegian4x4,
    int? repCount,
    String? recoveryLabel,
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
      repCount: repCount,
      recoveryLabel: recoveryLabel,
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

/// Words and number formats of one verdict (Phase 3 §3.7). The Norwegian
/// 4x4 key keeps the Phase 2 copy word for word (migration golden); every
/// other session names itself, and a rep-time session reads in seconds per
/// rep instead of pace.
class _Ctx {
  _Ctx({
    required this.floor,
    required this.band,
    required this.inputsKey,
    required this.units,
    required this.isFourByFour,
    required this.sessionName,
    required this.nominalRepMetres,
    required this.parkrun,
    required this.singleRep,
    required this.names,
    this.officialTime = false,
  });

  /// Run 3+ floor for the key (plan §3.7 W1); run 2 uses ×√2.
  final double floor;
  final double band;
  final String inputsKey;
  final Units units;
  final bool isFourByFour;
  final String sessionName;

  /// Set only for rep-time sessions.
  final int? nominalRepMetres;

  /// Parkrun: the headline is the finish time; with [officialTime] it is
  /// the runner's official time from the sidecar, not the GPS one (K1).
  final bool parkrun;
  final bool officialTime;

  /// The event's flavour name; never a literal here (K1).
  final EventNames names;

  /// One rep: no spread sentence, no "average".
  final bool singleRep;

  double get run2Floor => floor * math.sqrt2;
  bool get repTime => nominalRepMetres != null;
  double get _km => nominalRepMetres! / 1000;

  String get one => isFourByFour
      ? '4x4'
      : parkrun
      ? names.parkrun
      : '$sessionName session';
  String get many => isFourByFour
      ? '4x4s'
      : parkrun
      ? names.parkrunPlural
      : '$sessionName sessions';
  String get mismatch => isFourByFour
      ? 'Laps do not match a 4x4. Fix laps to get a verdict.'
      : 'Laps do not match the session. Fix laps to get a verdict.';
  String get metric => parkrun
      ? 'Finish time'
      : repTime
      ? 'Rep time'
      : 'Work pace';

  /// Headline number with its unit: "4:44/km" or "1:31".
  String value(double secPerKm) => repTime
      ? PaceFormat.mmss(secPerKm * _km)
      : PaceFormat.pace(secPerKm, units);

  /// "4:44" (for "4:44 vs 4:58/km") or "1:29" (for "1:29 vs 1:31").
  String bare(double secPerKm) => repTime
      ? PaceFormat.mmss(secPerKm * _km)
      : PaceFormat.paceBare(secPerKm, units);

  /// "14 s/km" or, per rep, "2 s".
  String delta(double deltaSecPerKm) => repTime
      ? PaceFormat.seconds(deltaSecPerKm * _km)
      : PaceFormat.delta(deltaSecPerKm, units);

  /// A spread or fade in the headline's unit, as "5 s".
  String gap(double secPerKm) => repTime
      ? PaceFormat.seconds(secPerKm * _km)
      : PaceFormat.seconds(PaceFormat.toUnit(secPerKm, units));

  /// The decision uses the displayed (rounded) numbers so a printed delta
  /// can never sit inside a printed floor: per rep for rep-time sessions.
  bool beyond(double delta, double floor) => repTime
      ? (delta * _km).round() > (floor * _km).round()
      : delta.round() > floor.round();
}

/// Staged verdict + copy pinned to the design brief's verdict copy set.
/// Stateless: every call derives its floor and copy from its own inputs
/// (#21 review P3), so one builder can serve concurrent analyses.
class VerdictBuilder {
  const VerdictBuilder(this.constants, {this.names = EventNames.generic});

  final EngineConstants constants;
  final EventNames names;

  /// [session] is the run's own planned session (null for a by-feel 4x4):
  /// its name labels the copy and its reps/recovery feed the D4 note.
  /// [minCleanReps] is how many clean reps a verdict needs (3 for a 4x4).
  Verdict build({
    required RunFile run,
    required RepDetection detection,
    required IntervalMetrics metrics,
    required VerdictGates gates,
    required List<PriorRun> priors,
    required DateTime now,
    String inputsKey = '',
    String comparisonKey = ComparisonKey.norwegian4x4,
    SessionSpec? templateDefault,
    SessionSpec? session,
    int minCleanReps = EngineConstants.minReps,
    bool officialTime = false,
  }) {
    final c = _Ctx(
      floor: constants.floorSecPerKmForKey(
        comparisonKey,
        templateDefault: templateDefault,
        officialTime: officialTime,
      ),
      band: constants.repBandSecPerKm,
      inputsKey: inputsKey,
      units: run.units,
      isFourByFour: comparisonKey == ComparisonKey.norwegian4x4,
      sessionName: session?.name ?? templateDefault?.name ?? 'interval',
      nominalRepMetres: metrics.kind == IntervalMetricKind.repTime
          ? metrics.nominalRepMetres
          : null,
      parkrun: ComparisonKey.isParkrun(comparisonKey),
      officialTime: officialTime && ComparisonKey.isParkrun(comparisonKey),
      names: names,
      singleRep: (session?.repCount ?? metrics.reps.length) == 1,
    );
    final same = [
      for (final p in priors)
        if (p.comparisonKey == comparisonKey) p,
    ];

    Verdict none(VerdictHeadline headline, String subline, {String? hrLine}) =>
        Verdict(
          stage: VerdictStage.none,
          headline: headline,
          subline: subline,
          hrLine: hrLine,
          currentSecPerKm: metrics.avgWorkPaceSecPerKm,
          floorSecPerKm: c.floor,
          bandSecPerKm: c.band,
          engineVersion: engineVersion,
          computedAt: now,
          inputsKey: c.inputsKey,
          nominalRepMetres: c.nominalRepMetres,
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
      return none(VerdictHeadline.noVerdict, c.mismatch);
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

    if (metrics.cleanRepCount < minCleanReps) {
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

    final eligible = same.where((p) => p.start.isBefore(run.start)).toList()
      ..sort((a, b) => a.start.compareTo(b.start));

    if (eligible.isEmpty) return _baseline(c, metrics, now);
    final note = _comparisonNote(eligible.last, session, metrics);
    if (eligible.length == 1) {
      return _vsLast(c, metrics, eligible.single, now, note);
    }
    return _vsMedian(c, run, metrics, eligible, now, note);
  }

  /// D4: "Last time: 5 reps, 2:30 recovery." when the last comparable run
  /// had a different rep count or recovery; null when they match or either
  /// side is unknown.
  static String? _comparisonNote(
    PriorRun last,
    SessionSpec? session,
    IntervalMetrics m,
  ) {
    final reps = session?.repCount ?? m.reps.length;
    final recovery = session == null ? null : recoveryLabelOf(session);
    final repsDiffer = last.repCount != null && last.repCount != reps;
    final recoveryDiffers =
        last.recoveryLabel != null &&
        recovery != null &&
        last.recoveryLabel != recovery;
    if (!repsDiffer && !recoveryDiffers) return null;
    final parts = [
      if (last.repCount != null) '${last.repCount} reps',
      ?last.recoveryLabel,
    ];
    return 'Last time: ${parts.join(', ')}.';
  }

  /// "2:30 recovery", "200 m jog", "equal-time jog", "no recovery".
  static String recoveryLabelOf(SessionSpec session) {
    final rec = session.steps.where((s) => !s.isWork).firstOrNull;
    if (rec == null) return 'no recovery';
    return switch (rec.target) {
      TargetKind.time =>
        rec.value == 0
            ? 'no recovery'
            : '${PaceFormat.mmss(rec.value.toDouble())} ${rec.style == RecoveryStyle.jog ? 'recovery' : rec.style.name}',
      TargetKind.distance => '${rec.value} m ${rec.style.name}',
      TargetKind.equalToPreviousWork => 'equal-time ${rec.style.name}',
    };
  }

  Verdict _baseline(_Ctx c, IntervalMetrics m, DateTime now) {
    final units = c.units;
    final spread = m.repSpreadSecPerKm!;
    final spreadText = c.singleRep
        ? ''
        : spread <= constants.repBandSecPerKm
        ? ' Reps within ${c.gap(spread)} of each other.'
        : ' Reps spread ${c.gap(spread)}.';
    final recovery = m.recoveryPaceSecPerKm;
    final recoveryText = recovery == null
        ? ''
        : ' Recovery ${PaceFormat.paceBare(recovery, units)}.';
    final avg = m.avgWorkPaceSecPerKm!;
    final lead = c.parkrun
        ? 'Finish ${c.value(avg)}${c.officialTime ? ' (official)' : ''}.'
        : c.repTime
        ? '${c.nominalRepMetres} m in ${c.value(avg)}${c.singleRep ? '' : ' average'}.'
        : '${c.value(avg)} work pace.';
    return Verdict(
      stage: VerdictStage.baseline,
      headline: VerdictHeadline.baselineSet,
      subline: '$lead$spreadText$recoveryText Next ${c.one} gets a verdict.',
      hrLine: m.timeInZoneSeconds == null
          ? null
          : 'Time in zone ${PaceFormat.mmss(m.timeInZoneSeconds!)} of '
                '${PaceFormat.mmss(m.workSeconds)}.',
      currentSecPerKm: m.avgWorkPaceSecPerKm,
      floorSecPerKm: c.floor,
      bandSecPerKm: c.band,
      engineVersion: engineVersion,
      computedAt: now,
      inputsKey: c.inputsKey,
      nominalRepMetres: c.nominalRepMetres,
    );
  }

  Verdict _vsLast(
    _Ctx c,
    IntervalMetrics m,
    PriorRun last,
    DateTime now,
    String? note,
  ) {
    final current = m.avgWorkPaceSecPerKm!;
    final baseline = last.avgWorkPaceSecPerKm;
    final delta = baseline - current;
    final floor = c.run2Floor;
    final vs = '(${c.bare(current)} vs ${c.value(baseline)})';
    final VerdictHeadline headline;
    final String subline;
    String? hrLine;
    if (c.beyond(delta, floor)) {
      headline = VerdictHeadline.faster;
      subline =
          '${c.metric} ${c.delta(delta)} faster than your first ${c.one} $vs.'
          '${_fadeSentence(c, m, last)}';
      hrLine = _fasterHrLine(m, last, [last]);
    } else if (c.beyond(-delta, floor)) {
      headline = VerdictHeadline.slower;
      subline =
          '${c.metric} ${c.delta(delta)} slower than your first ${c.one} $vs.'
          '${_fadeSentence(c, m, last)}';
      hrLine = _slowerHrLine(m, last);
    } else {
      headline = VerdictHeadline.noRealChange;
      final shown = c.repTime ? (delta * c._km).round() : delta.round();
      final lead = shown == 0
          ? 'Same ${c.metric.toLowerCase()} as your first ${c.one} '
                '(${c.value(current)}).'
          : '${c.delta(delta)} ${delta > 0 ? 'faster' : 'slower'} '
                'than your first ${c.one} $vs.';
      subline = '$lead Inside what phone GPS can tell (${c.delta(floor)}).';
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
      bandSecPerKm: c.band,
      engineVersion: engineVersion,
      computedAt: now,
      inputsKey: c.inputsKey,
      comparisonNote: note,
      nominalRepMetres: c.nominalRepMetres,
    );
  }

  Verdict _vsMedian(
    _Ctx c,
    RunFile run,
    IntervalMetrics m,
    List<PriorRun> eligible,
    DateTime now,
    String? note,
  ) {
    final units = c.units;
    final current = m.avgWorkPaceSecPerKm!;
    final set = eligible.length > constants.medianSetSize
        ? eligible.sublist(eligible.length - constants.medianSetSize)
        : eligible;
    final baseline = _median(set.map((p) => p.avgWorkPaceSecPerKm).toList());
    final delta = baseline - current;
    final floor = c.floor;
    final rank = set.where((p) => p.avgWorkPaceSecPerKm > current).length;
    final last = set.last;
    final vs = '(${c.bare(current)} vs ${c.value(baseline)})';

    final VerdictHeadline headline;
    final String subline;
    String? hrLine;
    if (c.beyond(delta, floor)) {
      headline = VerdictHeadline.faster;
      subline =
          '${c.metric} ${c.delta(delta)} faster than your recent ${c.many} $vs.'
          '${_fadeSentence(c, m, last)}';
      hrLine = _fasterHrLine(m, last, set);
    } else if (c.beyond(-delta, floor)) {
      headline = VerdictHeadline.slower;
      subline =
          '${c.metric} ${c.delta(delta)} slower than your recent ${c.many} $vs.'
          '${_fadeSentence(c, m, last)}';
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
          'Within ${c.delta(delta)} of your recent ${c.many} $vs.$recoveryText';
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
      bandSecPerKm: c.band,
      engineVersion: engineVersion,
      computedAt: now,
      inputsKey: c.inputsKey,
      bestIn365Days: best,
      trendSecPerKmPerWeek: theilSenSlope(run.start, current, eligible),
      comparisonNote: note,
      nominalRepMetres: c.nominalRepMetres,
    );
  }

  String _fadeSentence(_Ctx c, IntervalMetrics m, PriorRun last) {
    final fade = m.fadeSecPerKm;
    if (fade == null) return '';
    final was = last.fadeSecPerKm;
    final fadeText = c.gap(fade);
    if (was == null) return ' Fade $fadeText.';
    return ' Fade $fadeText, was ${c.gap(was)}.';
  }

  /// Plan §5 "faster at the same HR": pace better AND metres-per-beat better
  /// than the baseline (median mpb of the comparison set) → same-HR line;
  /// pace better but mpb worse → "it cost more". Falls back to % max HR
  /// when mpb is unavailable, and to time in zone when no prior has HR.
  String? _fasterHrLine(IntervalMetrics m, PriorRun last, List<PriorRun> set) {
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

  String? _holdingHrLine(IntervalMetrics m, PriorRun last) {
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

  String? _slowerHrLine(IntervalMetrics m, PriorRun last) {
    final hr = m.meanWorkHr;
    if (hr == null) return null;
    final was = last.meanWorkHr;
    if (was != null && was - hr >= 2) {
      return 'HR ${(was - hr).round()} bpm lower: easier day, not a worse one.';
    }
    return _timeInZoneOf(m);
  }

  String? _timeInZoneOf(IntervalMetrics m) {
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
