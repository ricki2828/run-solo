import 'dart:math' as math;

import '../model/session_spec.dart';
import '../run_mode.dart';
import 'best_efforts.dart';
import 'coaching_rules.dart';
import 'constants.dart';

/// Research norms and research-derived copy (Phase 4 plan §3.6, §4 R4/R5).
/// Every line here carries "research-based" (string lint, WARN-4).
abstract final class ResearchNorms {
  /// "People your age" stays off until the FRIEND 2022 per-decade
  /// percentile table is read from the primary paper (plan §3.6, §4 R4: the
  /// publisher blocks automated access; founder download or ACSM
  /// Guidelines 11th ed.). RV4 read the 2015 table (C11) but main chose
  /// option (b): wait for 2022, which reads 1.5–4.6 lower, rather than ship
  /// 2015 bands. While off, [peopleYourAge] returns null.
  static const bool peopleYourAgeEnabled = false;

  static const String peopleYourAgeSource =
      'Research-based norms (FRIEND registry, lab treadmill tests)';

  /// Verified endpoints only, not a table: FRIEND 2015 (Kaminsky, Arena,
  /// Myers 2015, Mayo Clin Proc 90:1515–23, 7783 treadmill tests; §4 R4
  /// [S14]) 50th percentile VO2max, ml/kg/min. The 2022 update (S15) reads
  /// 1.5–4.6 lower; its decade table is not read, so nothing ships yet.
  static const Map<String, double> friend2015Median = {
    'men 20-29': 48.0,
    'women 20-29': 37.6,
    'men 70-79': 24.4,
    'women 70-79': 18.3,
  };

  /// The qualitative pacing norm (§4 R5). No verified recreational 5K/10K
  /// second-half number exists, so no number ships; the rule table keeps a
  /// slot for one once a primary source is read.
  /// Elite racing only (RV4 C4): the sources are world-record and
  /// championship races, so it must not read as a norm for everyday runs.
  static const String fadeNormLine =
      'Elite 5K and 10K runners usually hold an even pace through the '
      'middle and finish fast (research-based, from world-record and '
      'championship races; may not fit everyday runs).';

  /// Numeric second-half norm, off until sourced (§4 R5: NV).
  static const double? fadeNormPercent = null;

  /// The runner's place in the norms for their age (design A10.5): one
  /// mark for a known [sex], both when it is not set and [whenSexUnset] is
  /// [NormsWhenSexUnset.bothRanges]; null for [NormsWhenSexUnset.hidden].
  /// Null while [peopleYourAgeEnabled] is false (no table to read yet).
  static PeopleYourAge? peopleYourAge({
    required double vo2,
    required int age,
    NormsSex? sex,
    NormsWhenSexUnset whenSexUnset = NormsWhenSexUnset.bothRanges,
  }) => null;
}

/// Sex for the fitness norms (Settings → Profile, CR2); null = not set.
enum NormsSex { male, female }

/// What "People your age" does when sex is not set (design A10.5, founder
/// may switch it).
enum NormsWhenSexUnset { bothRanges, hidden }

/// One "People your age" result: the dots on the band and the line.
class PeopleYourAge {
  const PeopleYourAge({required this.marks, required this.line});

  /// (who, percentile 0..100): one mark, or men and women when sex is
  /// not set.
  final List<(NormsSex, int)> marks;

  /// "About the 60th percentile for men 40 to 49", or "About 60th (men) ·
  /// 75th (women), 40 to 49".
  final String line;

  /// Shown under the line, always.
  String get source => ResearchNorms.peopleYourAgeSource;
}

/// What the after-run coaching says: at most one observation.
class CoachObservation {
  const CoachObservation(this.text, {this.researchBased = false});
  final String text;
  final bool researchBased;
}

/// A "try next" suggestion: never a schedule, at most one.
enum SuggestionKind { zone2LongRun, fewerReps, norwegian4x4 }

class CoachSuggestion {
  const CoachSuggestion(this.kind, this.text, {this.key});

  final SuggestionKind kind;
  final String text;

  /// The interval key a [SuggestionKind.fewerReps] is about.
  final String? key;

  static const String zone2Text =
      'Try a longer easy run this week, Zone 2, 60 to 75 min.';
  static const String fewerRepsText =
      'Try one fewer rep, or 30 s more recovery, next time.';
  static const String norwegianText =
      'Add one Norwegian 4x4 a week for a month, then retest.';

  /// The Home card disappears once the suggested session type is run.
  bool doneBy(CoachRun r) => switch (kind) {
    SuggestionKind.zone2LongRun => r.durationMs >= CoachReporter.longRunMs,
    SuggestionKind.fewerReps => r.comparisonKey == key,
    SuggestionKind.norwegian4x4 =>
      r.comparisonKey == ComparisonKey.norwegian4x4,
  };

  Map<String, Object?> toJson() => {
    'kind': kind.name,
    'text': text,
    'key': key,
  };
}

class CoachReport {
  const CoachReport({this.observation, this.suggestion});
  final CoachObservation? observation;
  final CoachSuggestion? suggestion;
}

/// After-run coaching (plan §3.6, CR1): one observation and one suggestion
/// from a fixed rule table, from the runner's own history.
class CoachReporter {
  const CoachReporter([this.constants = EngineConstants.defaults]);

  final EngineConstants constants;

  /// A second half this much slower (fraction) is a fade.
  static const double fadeAt = 0.03;

  /// Fade vs usual is worth saying past this many points.
  static const double usualGap = 0.01;

  /// "Your usual" needs this many earlier efforts.
  static const int usualMin = 3;
  static const int usualOver = 6;

  static const int longRunMs = 60 * 60 * 1000;
  static const Duration longRunWindow = Duration(days: 28);

  /// Cooper VO2 spread at or under this over the last 3 tests is "flat".
  static const double cooperFlatWithin = 1.0;

  CoachReport report({required CoachRun run, required List<CoachRun> history}) {
    final earlier = [
      for (final r in history)
        if (r.date.isBefore(run.date) && r.runId != run.runId) r,
    ]..sort((a, b) => a.date.compareTo(b.date));
    return CoachReport(
      observation: _observation(run, earlier),
      suggestion: _suggestion(run, earlier),
    );
  }

  /// Second half vs first half of the run's longest board window (10K
  /// before 5K), as a fraction (0.04 = 4% slower); null without one.
  static double? halfFade(CoachRun r) {
    for (final d in [BestEffortDistance.k10, BestEffortDistance.k5]) {
      final e = r.derived.bestEfforts.efforts[d];
      if (e == null || e.splitsMs.isEmpty) continue;
      final half = d.metres / 2;
      final km = half / 1000;
      final lo = km.floor();
      double at(int k) => k == 0 ? 0 : e.splitsMs[k - 1].toDouble();
      final tHalf = lo == km
          ? at(lo)
          : at(lo) + (at(lo + 1) - at(lo)) * (km - lo);
      if (tHalf <= 0) return null;
      return (e.elapsedMs - tHalf) / tHalf - 1;
    }
    return null;
  }

  static BestEffortDistance? _boardOf(CoachRun r) =>
      r.derived.bestEfforts.efforts.containsKey(BestEffortDistance.k10)
      ? BestEffortDistance.k10
      : r.derived.bestEfforts.efforts.containsKey(BestEffortDistance.k5)
      ? BestEffortDistance.k5
      : null;

  CoachObservation? _observation(CoachRun run, List<CoachRun> earlier) {
    if (run.mode == RunMode.intervals && run.comparisonKey != null) {
      return _repObservation(run, earlier);
    }
    final f = halfFade(run);
    final board = _boardOf(run);
    if (f == null || board == null) return null;
    final usual = [
      for (final r in earlier.reversed)
        if (_boardOf(r) == board) ?halfFade(r),
    ].take(usualOver).toList();
    if (usual.length >= usualMin) {
      final u = _median(usual);
      if ((f - u).abs() < usualGap) return null;
      final mine = _pct(f);
      final theirs = _pct(u);
      if (f.abs() < 0.005) {
        return CoachObservation(
          'You ran even halves. Your usual is $theirs% slower in the second '
          'half.',
        );
      }
      if (f < 0) {
        return CoachObservation(
          'You finished faster than you started. Your usual is $theirs% '
          'slower in the second half.',
        );
      }
      return f > u
          ? CoachObservation(
              'You slowed $mine% in the second half. Your usual is $theirs%.',
            )
          : CoachObservation(
              'Evener than usual: $mine% slower in the second half, your '
              'usual is $theirs%.',
            );
    }
    return f >= fadeAt
        ? const CoachObservation(
            ResearchNorms.fadeNormLine,
            researchBased: true,
          )
        : null;
  }

  CoachObservation? _repObservation(CoachRun run, List<CoachRun> earlier) {
    final mine = _repFade(run);
    if (mine == null) return null;
    final usual = [
      for (final r in earlier.reversed)
        if (r.comparisonKey == run.comparisonKey) ?_repFade(r),
    ].take(usualOver).toList();
    if (usual.length < usualMin) return null;
    final u = _median(usual);
    final floor = constants.floorSecPerKmForKey(run.comparisonKey!);
    if (mine - u < floor / 2) return null;
    return CoachObservation(
      'Your last rep was ${mine.round()} s/km slower than your first. Your '
      'usual is ${u.round()} s/km.',
    );
  }

  /// Last clean rep minus first clean rep (live, untrimmed), s/km.
  static double? _repFade(CoachRun r) {
    final clean = r.repPaces.whereType<double>().toList();
    return clean.length < 2 ? null : clean.last - clean.first;
  }

  CoachSuggestion? _suggestion(CoachRun run, List<CoachRun> earlier) {
    // Cooper VO2 flat for 3 tests.
    if (run.mode == RunMode.cooper && run.cooperVo2 != null) {
      final vo2 = [
        for (final r in earlier)
          if (r.mode == RunMode.cooper && r.cooperVo2 != null) r.cooperVo2!,
        run.cooperVo2!,
      ];
      if (vo2.length >= 3) {
        final last3 = vo2.sublist(vo2.length - 3);
        if (last3.reduce(math.max) - last3.reduce(math.min) <=
            cooperFlatWithin) {
          return const CoachSuggestion(
            SuggestionKind.norwegian4x4,
            CoachSuggestion.norwegianText,
          );
        }
      }
      return null;
    }
    // Rep fade in 3 of the last 4 sessions of this key.
    if (run.mode == RunMode.intervals && run.comparisonKey != null) {
      final key = run.comparisonKey!;
      final floor = constants.floorSecPerKmForKey(key);
      final sessions = [
        for (final r in earlier)
          if (r.comparisonKey == key) r,
        run,
      ];
      final last4 = sessions.sublist(math.max(0, sessions.length - 4));
      final faded = last4.where((r) => (_repFade(r) ?? 0) > floor).length;
      if (last4.length == 4 && faded >= 3) {
        return CoachSuggestion(
          SuggestionKind.fewerReps,
          CoachSuggestion.fewerRepsText,
          key: key,
        );
      }
      return null;
    }
    // 10K fade in 2 of the last 3 similar efforts, and no run of 60 min or
    // more in 4 weeks. One bad day is pacing, fuel or heat, not a base gap
    // (science review): never off a single run.
    if (_boardOf(run) == BestEffortDistance.k10) {
      final tens = [
        for (final r in earlier)
          if (_boardOf(r) == BestEffortDistance.k10) r,
        run,
      ];
      final last3 = tens.sublist(math.max(0, tens.length - 3));
      final faded = last3.where((r) => (halfFade(r) ?? 0) >= fadeAt).length;
      final since = run.date.subtract(longRunWindow);
      final longRun = [
        ...earlier,
        run,
      ].any((r) => !r.date.isBefore(since) && r.durationMs >= longRunMs);
      if (last3.length == 3 && faded >= 2 && !longRun) {
        return const CoachSuggestion(
          SuggestionKind.zone2LongRun,
          CoachSuggestion.zone2Text,
        );
      }
    }
    return null;
  }

  static String _pct(double f) => (f.abs() * 100).round().toString();

  static double _median(List<double> v) {
    final s = [...v]..sort();
    final m = s.length ~/ 2;
    return s.length.isOdd ? s[m] : (s[m - 1] + s[m]) / 2;
  }
}
