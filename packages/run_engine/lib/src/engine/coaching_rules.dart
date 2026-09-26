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

/// HR drift (plan §3.5, "HR above your median for runs of similar pace"):
/// at km k (k ≥ [firstKm], after km 3) native takes the prior (pace, HR)
/// pairs at that km, `kmSamples[k − 1]`, keeps those whose pace is within
/// ±[paceBand] of the live km-k pace, and fires when there are at least
/// [minSimilar] of them and the live km-k mean HR is at least their median
/// HR + [bpmOver]. Pairing at run time, not a median pace with a median HR:
/// with easy and hard runs in the history those medians describe a run
/// nobody ran (#56 review P2). Live km HR uses the same rule as the engine
/// (`LiveFigures.kmHr`: mean of HR samples in the km, none under half
/// coverage).
class HrDriftRule {
  const HrDriftRule({required this.kmSamples, required this.text});

  /// Per km (index k − 1): the last ≤ 6 board runs' (pace s/km, mean HR) at
  /// that km; empty before [firstKm] or where no run had HR.
  final List<List<(double, double)>> kmSamples;
  final String text;

  static const double bpmOver = 5;
  static const double paceBand = 0.05;
  static const int firstKm = 4;
  static const int minSimilar = 3;

  Map<String, Object?> toJson() => {
    'kmSamples': [
      for (final km in kmSamples)
        [
          for (final (pace, hr) in km)
            [
              double.parse(pace.toStringAsFixed(1)),
              double.parse(hr.toStringAsFixed(1)),
            ],
        ],
    ],
    'bpmOver': bpmOver,
    'paceBand': paceBand,
    'firstKm': firstKm,
    'minSimilar': minSimilar,
    'text': text,
  };

  /// Decodes [toJson] (the journal / shared-fixture shape). The tuning
  /// constants are the engine's own; a plan that disagrees is refused.
  factory HrDriftRule.fromJson(Map<String, Object?> j) {
    for (final (k, v) in [
      ('bpmOver', bpmOver),
      ('paceBand', paceBand),
      ('firstKm', firstKm),
      ('minSimilar', minSimilar),
    ]) {
      if ((j[k] as num?)?.toDouble() != v.toDouble()) {
        throw FormatException('hrDrift.$k ${j[k]} != $v');
      }
    }
    return HrDriftRule(
      kmSamples: [
        for (final km in j['kmSamples']! as List)
          [
            for (final p in km as List)
              (((p as List)[0] as num).toDouble(), (p[1] as num).toDouble()),
          ],
      ],
      text: j['text']! as String,
    );
  }

  /// What native computes live, for the shared fixture: whether the rule
  /// fires at [km] (1-based) for a live pace and HR.
  bool firesAt(int km, {required double paceSecPerKm, required double hr}) {
    if (km < firstKm || km > kmSamples.length) return false;
    final similar = [
      for (final (p, h) in kmSamples[km - 1])
        if ((p - paceSecPerKm).abs() <= paceBand * paceSecPerKm) h,
    ];
    if (similar.length < minSimilar) return false;
    similar.sort();
    final m = similar.length ~/ 2;
    final median = similar.length.isOdd
        ? similar[m]
        : (similar[m - 1] + similar[m]) / 2;
    return hr >= median + bpmOver;
  }
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
      blocked: _blocked(ghosts),
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
    final kms = <List<(double, double)>>[];
    for (var k = 1; k <= boardKm; k++) {
      final pairs = <(double, double)>[];
      if (k >= HrDriftRule.firstKm) {
        for (final r in recent) {
          final kmHr = r.derived.live.kmHr;
          if (k > kmHr.length || kmHr[k - 1] == null) continue;
          final s = r.fromStartSplitsMs;
          pairs.add(((s[k - 1] - s[k - 2]) / 1000, kmHr[k - 1]!));
        }
      }
      kms.add(pairs);
    }
    // Some km must have enough runs to ever reach minSimilar.
    if (kms.every((p) => p.length < HrDriftRule.minSimilar)) return null;
    return HrDriftRule(kmSamples: kms, text: hrDriftText);
  }

  /// The fired nudges of the newest run on this board ([board] is the
  /// board's own history only, #56 review P3).
  static List<String> _blocked(List<CoachRun> board) {
    if (board.isEmpty) return const [];
    final last = board.reduce((a, b) => b.date.isAfter(a.date) ? b : a);
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
