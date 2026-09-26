import 'dart:math' as math;

import '../model/session_spec.dart';
import '../run_mode.dart';
import 'best_efforts.dart';
import 'constants.dart';
import 'live_figures.dart';

/// One past run as coaching sees it (built by the app from its index).
class CoachRun {
  const CoachRun({
    required this.runId,
    required this.date,
    required this.mode,
    required this.derived,
    required this.durationMs,
    this.comparisonKey,
    this.cooperVo2,
  });

  final String runId;
  final DateTime date;
  final RunMode mode;
  final String? comparisonKey;
  final RunDerived derived;

  /// Whole-run duration (the Zone 2 suggestion looks for runs ≥ 60 min).
  final int durationMs;

  /// A valid Cooper test's raw VO2 estimate.
  final double? cooperVo2;

  List<int> get fromStartSplitsMs => derived.bestEfforts.fromStartSplitsMs;
  List<double?> get repPaces => derived.live.repPacesSecPerKm;
}

/// Rule names, as journaled in `cue_fired` and blocked next run.
abstract final class NudgeRule {
  static const String fastStart = 'fast_start';
  static const String repFade = 'rep_fade';
  static const String hrDrift = 'hr_drift';
}

/// Fast start (plan §3.5): km 1 faster than [km1MaxMs] (4% quicker than
/// the PB's own km 1, and that PB started within 2% of its average km).
class FastStartRule {
  const FastStartRule({required this.km1MaxMs, required this.text});

  final int km1MaxMs;
  final String text;

  Map<String, Object?> toJson() => {'km1MaxMs': km1MaxMs, 'text': text};
}

/// Rep fade (plan §3.5): at the end of rep r ≥ 3, fires when the live rep r
/// pace minus the live rep 1 pace (untrimmed, s/km) exceeds
/// `maxDropSecPerKm[r − 1]` (null = off for that rep).
class RepFadeRule {
  const RepFadeRule({required this.maxDropSecPerKm, required this.text});

  final List<double?> maxDropSecPerKm;
  final String text;

  Map<String, Object?> toJson() => {
    'maxDropSecPerKm': [
      for (final v in maxDropSecPerKm)
        v == null ? null : double.parse(v.toStringAsFixed(1)),
    ],
    'text': text,
  };
}

/// HR drift (plan §3.5): at km k (k ≥ 4, after km 3), fires when the live
/// pace over km k is within ±[paceBand] of `kmPaceSecPerKm[k − 1]` and the
/// live mean HR over km k is at least `kmHr[k − 1]` + [bpmOver]. Both lists
/// are the runner's own medians at that km on this board.
class HrDriftRule {
  const HrDriftRule({
    required this.kmHr,
    required this.kmPaceSecPerKm,
    required this.text,
  });

  final List<double?> kmHr;
  final List<double?> kmPaceSecPerKm;
  final String text;

  static const double bpmOver = 5;
  static const double paceBand = 0.05;
  static const int firstKm = 4;

  Map<String, Object?> toJson() => {
    'kmHr': [
      for (final v in kmHr)
        v == null ? null : double.parse(v.toStringAsFixed(1)),
    ],
    'kmPaceSecPerKm': [
      for (final v in kmPaceSecPerKm)
        v == null ? null : double.parse(v.toStringAsFixed(1)),
    ],
    'bpmOver': bpmOver,
    'paceBand': paceBand,
    'firstKm': firstKm,
    'text': text,
  };
}

/// The in-run nudge plan (plan §3.5, fills LC1's `NudgePlan` stub). Built by
/// the engine from the runner's own history; native only evaluates it at an
/// existing cue. Limits native enforces: one nudge per km or rep, never in a
/// countdown (last 10 s of a recovery, 3-2-1, Cooper final 30 s), never in
/// the first km of a Cooper (Cooper gets no nudges at all, §3.2), never
/// when muted, and never at a `blocked` "rule:index" (the same nudge at the
/// same km or rep as last run, WARN-5).
class NudgePlanSpec {
  const NudgePlanSpec({
    this.fastStart,
    this.repFade,
    this.hrDrift,
    this.blocked = const [],
  });

  static const int version = 1;

  final FastStartRule? fastStart;
  final RepFadeRule? repFade;
  final HrDriftRule? hrDrift;

  /// "rule:index" pairs spoken on the previous run of this board.
  final List<String> blocked;

  bool get isEmpty => fastStart == null && repFade == null && hrDrift == null;

  /// The canonical JSON (journal `lctx` line, Kotlin `NudgePlan`).
  Map<String, Object?> toJson() => {
    'version': version,
    'fastStart': fastStart?.toJson(),
    'repFade': repFade?.toJson(),
    'hrDrift': hrDrift?.toJson(),
    'blocked': blocked,
  };
}

/// Builds the [NudgePlanSpec] for one board at Start (plan §3.5, CR1).
class CoachingRules {
  const CoachingRules([this.constants = EngineConstants.defaults]);

  final EngineConstants constants;

  /// A rule stays off until its board has this many usable entries.
  static const int minEntries = 3;

  /// Fast start: km 1 this much quicker than the PB's km 1…
  static const double fastStartMargin = 0.04;

  /// …and only when the PB itself went out within this of its average km.
  static const double pbEvenWithin = 0.02;

  /// Usual fade and HR are medians of this many recent sessions.
  static const int usualOver = 6;

  /// The spoken lines (Aussie casual, no numbers; engine-owned, pinned in
  /// fixtures). [boardLabel] is injected ("5K", or the event name).
  static String fastStartText(String boardLabel) =>
      'Easy start. Your best $boardLabel went out slower than this.';
  static const String repFadeText =
      'That one dropped off a bit. Hold your form on the next.';
  static const String hrDriftText =
      "Heart rate's up for this pace today. Fine to ease a touch.";

  /// The plan for a distance board ([boardKm] 5 or 10) from [history]
  /// (every earlier run on the board, any order), or null with no rule.
  NudgePlanSpec? forDistanceBoard({
    required int boardKm,
    required String boardLabel,
    required List<CoachRun> history,
  }) {
    final ghosts = [
      for (final r in history)
        if (r.fromStartSplitsMs.length >= boardKm) r,
    ];
    if (ghosts.length < minEntries) return null;
    final fast = _fastStart(ghosts, boardKm, boardLabel);
    final hr = _hrDrift(ghosts, boardKm);
    final plan = NudgePlanSpec(
      fastStart: fast,
      hrDrift: hr,
      blocked: _blocked(history),
    );
    return plan.isEmpty ? null : plan;
  }

  /// The plan for an interval board [key] from [history] (earlier sessions
  /// of that key), or null with no rule.
  NudgePlanSpec? forIntervalBoard({
    required String key,
    required List<CoachRun> history,
    SessionSpec? templateDefault,
  }) {
    final sessions = [
      for (final r in history)
        if (r.repPaces.isNotEmpty && r.repPaces.first != null) r,
    ]..sort((a, b) => a.date.compareTo(b.date));
    if (sessions.length < minEntries) return null;
    final recent = sessions.skip(math.max(0, sessions.length - usualOver));
    final floor = constants.floorSecPerKmForKey(
      key,
      templateDefault: templateDefault,
    );
    final reps = recent.map((r) => r.repPaces.length).reduce(math.max);
    final drops = <double?>[];
    for (var i = 0; i < reps; i++) {
      if (i < 2) {
        drops.add(null); // reps 1 and 2 never fire
        continue;
      }
      final fades = [
        for (final r in recent)
          if (i < r.repPaces.length && r.repPaces[i] != null)
            r.repPaces[i]! - r.repPaces.first!,
      ];
      drops.add(
        fades.length < minEntries ? null : math.max(floor, _median(fades)),
      );
    }
    if (drops.every((d) => d == null)) return null;
    return NudgePlanSpec(
      repFade: RepFadeRule(maxDropSecPerKm: drops, text: repFadeText),
      blocked: _blocked(history),
    );
  }

  /// PB = the fastest ghost at the board distance; fires only when that PB
  /// went out evenly (km 1 within 2% of its average km).
  FastStartRule? _fastStart(
    List<CoachRun> ghosts,
    int boardKm,
    String boardLabel,
  ) {
    final pb = ghosts.reduce(
      (a, b) =>
          b.fromStartSplitsMs[boardKm - 1] < a.fromStartSplitsMs[boardKm - 1]
          ? b
          : a,
    );
    final km1 = pb.fromStartSplitsMs.first;
    final avgKm = pb.fromStartSplitsMs[boardKm - 1] / boardKm;
    if ((km1 - avgKm).abs() > avgKm * pbEvenWithin) return null;
    return FastStartRule(
      km1MaxMs: (km1 * (1 - fastStartMargin)).round(),
      text: fastStartText(boardLabel),
    );
  }

  HrDriftRule? _hrDrift(List<CoachRun> ghosts, int boardKm) {
    final recent = ([...ghosts]..sort((a, b) => a.date.compareTo(b.date)))
        .skip(math.max(0, ghosts.length - usualOver))
        .toList();
    final hr = <double?>[];
    final pace = <double?>[];
    for (var k = 1; k <= boardKm; k++) {
      if (k < HrDriftRule.firstKm) {
        hr.add(null);
        pace.add(null);
        continue;
      }
      final hs = <double>[];
      final ps = <double>[];
      for (final r in recent) {
        final kmHr = r.derived.live.kmHr;
        if (k > kmHr.length || kmHr[k - 1] == null) continue;
        hs.add(kmHr[k - 1]!);
        final s = r.fromStartSplitsMs;
        ps.add((s[k - 1] - s[k - 2]) / 1000);
      }
      final ok = hs.length >= minEntries;
      hr.add(ok ? _median(hs) : null);
      pace.add(ok ? _median(ps) : null);
    }
    if (hr.every((h) => h == null)) return null;
    return HrDriftRule(kmHr: hr, kmPaceSecPerKm: pace, text: hrDriftText);
  }

  /// The previous run's fired nudges (the newest run in [history]).
  static List<String> _blocked(List<CoachRun> history) {
    if (history.isEmpty) return const [];
    final last = history.reduce((a, b) => b.date.isAfter(a.date) ? b : a);
    return [for (final n in last.derived.nudgesFired) '${n.rule}:${n.index}'];
  }

  static double _median(List<double> v) {
    final s = [...v]..sort();
    final m = s.length ~/ 2;
    return s.length.isOdd ? s[m] : (s[m - 1] + s[m]) / 2;
  }
}

/// The best-effort distance a Free/Laps live board races (5K or 10K).
int? boardKmOf(String key) => switch (BestEffortDistance.ofKey(key)) {
  BestEffortDistance.k5 => 5,
  BestEffortDistance.k10 => 10,
  _ => null,
};
