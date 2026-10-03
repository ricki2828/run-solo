import '../model/session_spec.dart';
import 'run_identity.dart';
import '../run_mode.dart';
import 'best_efforts.dart';
import 'fitness_hero.dart';
import 'live_plan.dart';
import 'trail_verdict.dart';

/// Stable identity readings built from verified run evidence, never a verdict.
/// A score is only shown when its lane has an eligible observation. We use
/// the strongest effort in a rolling six-week window, not the latest run;
/// ordinary easy days cannot abruptly lower an identity score.
enum IdentityLane { aerobic, speed, mid, long }

class IdentityScore {
  const IdentityScore({
    required this.lane,
    required this.score,
    required this.vdot,
    required this.runId,
    required this.date,
    required this.source,
    required this.boardKey,
    this.changeVs6Weeks,
    this.priorVdot,
    this.priorSource,
  });

  final IdentityLane lane;
  final int score;

  /// Run-derived VDOT estimate underlying the app-specific 0-99 display.
  final double vdot;
  final int? changeVs6Weeks;

  /// The same lane's reading six weeks ago (VDOT and what set it), so a
  /// screen can compare in its own units; null when that window was empty.
  final double? priorVdot;
  final String? priorSource;
  final String runId;
  final DateTime date;
  final String source;
  final String? boardKey;
}

abstract final class IdentityScores {
  static const window = Duration(days: 42);

  /// VDOT is a capacity estimate, not a score. A bounded, deliberately broad
  /// display scale maps 20..80 VDOT to 20..99 with rounded integers; it is
  /// not a new VO2 estimate. Use the same mapping for all four lanes.
  static int displayScore(double vdot) =>
      (20 + (vdot - 20) * 79 / 60).round().clamp(0, 99);

  static Map<IdentityLane, IdentityScore> of(
    Iterable<LiveCandidate> runs, {
    required DateTime now,
    FitnessHero? hero,
  }) {
    final out = <IdentityLane, IdentityScore>{};
    final all = runs.toList();
    final aerobic = hero ?? FitnessHero.of(all, now: now);
    if (aerobic != null) {
      out[IdentityLane.aerobic] = IdentityScore(
        lane: IdentityLane.aerobic,
        score: displayScore(aerobic.vo2),
        vdot: aerobic.vo2,
        changeVs6Weeks: aerobic.deltaVs6wks == null
            ? null
            : displayScore(aerobic.vo2) -
                  displayScore(aerobic.vo2 - aerobic.deltaVs6wks!),
        priorVdot: aerobic.deltaVs6wks == null
            ? null
            : aerobic.vo2 - aerobic.deltaVs6wks!,
        priorSource: aerobic.deltaVs6wks == null ? null : aerobic.sourceLabel,
        runId: aerobic.runId,
        date: aerobic.asOf,
        source: aerobic.sourceLabel,
        boardKey: aerobic.sourceLabel == 'Cooper test' ? 'cooper' : null,
      );
    }
    for (final lane in [
      IdentityLane.speed,
      IdentityLane.mid,
      IdentityLane.long,
    ]) {
      final obs = <_Evidence>[];
      for (final c in all) {
        final input = c.input;
        if (input.date.isAfter(now)) continue;
        void add(
          double metres,
          int milliseconds,
          String source,
          String? board, [
          double? grade,
        ]) {
          if (milliseconds <= 0) return;
          final adjusted = input
              .factorsFor(grade)
              .apply(milliseconds.toDouble())
              .round();
          obs.add(
            _Evidence(
              input.runId,
              RunIdentity.localStart(input.date, input.utcOffsetMin),
              FitnessHero.vdot(metres, adjusted),
              source,
              board,
            ),
          );
        }

        final efforts = c.derived.bestEfforts;
        if (lane == IdentityLane.speed) {
          // SPEED unlocks only on a clean, verdict-grade interval session;
          // isolated GPS spikes in a Free run cannot unlock it.
          if (input.mode != RunMode.intervals || !input.verdictGrade) continue;
          for (final d in [BestEffortDistance.km1, BestEffortDistance.mile]) {
            if (efforts.efforts[d] case final e?) {
              add(
                d.metres,
                e.elapsedMs,
                d == BestEffortDistance.km1 ? '1K' : 'mile',
                d.key,
                e.gradeFactor,
              );
            }
          }
          if (input.headlineSecPerKm case final pace?) {
            if (pace > 0 && input.comparisonKey == ComparisonKey.norwegian4x4) {
              add(
                1000,
                (pace * 1000).round(),
                '4x4 work pace',
                input.comparisonKey,
                input.headlineGradeFactor,
              );
            }
          }
        } else if (lane == IdentityLane.mid) {
          // A real clean 5K/10K GPS window counts despite an INT mode pick.
          // The finder still rejects indoor/noisy tracks and cuts pauses,
          // recording gaps and GPS jumps. Cooper is a 12-minute test.
          if (input.mode == RunMode.cooper || input.mode == RunMode.trail) {
            continue;
          }
          for (final d in [BestEffortDistance.k5, BestEffortDistance.k10]) {
            if (efforts.efforts[d] case final e?) {
              add(
                d.metres,
                e.elapsedMs,
                d == BestEffortDistance.k5 ? '5K' : '10K',
                d.key,
                e.gradeFactor,
              );
            }
          }
        } else {
          // LONG: a Trail run of 15 km or more counts at its true pace (see
          // TrailScore), never at its hilly pace.
          if (input.mode == RunMode.trail) {
            final d = input.trailDistanceM, ms = input.trailMovingMs;
            if (d != null && ms != null && d >= 15000) {
              add(d, ms, TrailScore.longSource, null);
            }
            continue;
          }
          if (input.mode != RunMode.free &&
              input.mode != RunMode.laps &&
              !(input.mode == RunMode.intervals &&
                  ComparisonKey.isGoal(input.comparisonKey ?? ''))) {
            continue;
          }
          for (final d in [
            BestEffortDistance.half,
            BestEffortDistance.marathon,
          ]) {
            if (efforts.efforts[d] case final e?) {
              add(
                d.metres,
                e.elapsedMs,
                d == BestEffortDistance.half ? 'Half marathon' : 'Marathon',
                d.key,
                e.gradeFactor,
              );
            }
          }
          if ((input.mode == RunMode.free || input.mode == RunMode.laps) &&
              (efforts.wholeRunM ?? 0) >= 15000 &&
              efforts.wholeRunMs != null) {
            add(efforts.wholeRunM!, efforts.wholeRunMs!, '15K+ run', null);
          }
        }
      }
      _Evidence? best(DateTime from, DateTime to) {
        _Evidence? winner;
        for (final e in obs) {
          if (e.date.isBefore(from) || !e.date.isBefore(to)) continue;
          if (winner == null || e.vdot > winner.vdot) winner = e;
        }
        return winner;
      }

      final current = best(now.subtract(window), now);
      if (current == null) continue;
      final prior = best(now.subtract(window * 2), now.subtract(window));
      out[lane] = IdentityScore(
        lane: lane,
        score: displayScore(current.vdot),
        vdot: current.vdot,
        changeVs6Weeks: prior == null
            ? null
            : displayScore(current.vdot) - displayScore(prior.vdot),
        priorVdot: prior?.vdot,
        priorSource: prior?.source,
        runId: current.runId,
        date: current.date,
        source: current.source,
        boardKey: current.boardKey,
      );
    }
    return out;
  }
}

class _Evidence {
  const _Evidence(this.runId, this.date, this.vdot, this.source, this.boardKey);
  final String runId;
  final DateTime date;
  final double vdot;
  final String source;
  final String? boardKey;
}
