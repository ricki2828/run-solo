/// The 4-week progress block on the phone: one plan in
/// `files/state/plan.json`, the runs it is judged against, and the Start
/// preset for each session. The planning rules live in the engine
/// (`block_plan.dart`); nothing here decides anything.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:run_engine/run_engine.dart' as engine;

import '../app/format.dart';
import '../platform/gateway.dart';
import 'history_store.dart';
import 'sessions.dart';
import 'settings.dart';

abstract class BlockPlanStore {
  Future<engine.BlockPlan?> load();

  /// Null clears the plan.
  Future<void> save(engine.BlockPlan? plan);
}

class MemoryBlockPlanStore implements BlockPlanStore {
  MemoryBlockPlanStore([this.plan]);
  engine.BlockPlan? plan;

  @override
  Future<engine.BlockPlan?> load() async => plan;

  @override
  Future<void> save(engine.BlockPlan? plan) async => this.plan = plan;
}

/// A missing, damaged or newer file reads as no plan.
class FileBlockPlanStore implements BlockPlanStore {
  FileBlockPlanStore(this.stateDir);
  final Directory stateDir;

  File get file => File('${stateDir.path}/plan.json');

  @override
  Future<engine.BlockPlan?> load() async {
    try {
      if (!await file.exists()) return null;
      return engine.BlockPlan.tryParse(jsonDecode(await file.readAsString()));
    } catch (e) {
      debugPrint('plan: damaged file, no plan ($e)');
      return null;
    }
  }

  @override
  Future<void> save(engine.BlockPlan? plan) async {
    if (plan == null) {
      if (await file.exists()) await file.delete();
      return;
    }
    await stateDir.create(recursive: true);
    final tmp = File(
      '${file.path}.${DateTime.now().microsecondsSinceEpoch}.tmp',
    );
    await tmp.writeAsString(jsonEncode(plan.toJson()), flush: true);
    await tmp.rename(file.path);
  }
}

class BlockPlanController extends ChangeNotifier {
  BlockPlanController(this._store);
  final BlockPlanStore _store;
  engine.BlockPlan? _plan;
  Future<void> _writes = Future.value();

  engine.BlockPlan? get plan => _plan;

  Future<void> load() async {
    _plan = await _store.load();
    notifyListeners();
  }

  /// Tests and the fake APK start with a plan already in place.
  void preload(engine.BlockPlan? plan) => _plan = plan;

  Future<void> create(engine.BlockPlan plan) => _set(plan);

  /// Swap one session for [replacement] (same id), keeping the rest.
  Future<void> swap(engine.BlockSession replacement) {
    final p = _plan;
    if (p == null) return Future.value();
    return _set(p.withSession(replacement));
  }

  Future<void> end() => _set(null);

  Future<void> _set(engine.BlockPlan? plan) {
    _plan = plan;
    notifyListeners();
    return _writes = _writes.then((_) async {
      try {
        await _store.save(plan);
      } catch (e) {
        debugPrint('plan: save failed ($e)');
      }
    });
  }
}

/// What the plan reads from History: index-row fields only.
abstract final class PlanInputs {
  /// The run's start as the wall clock where it was run (its own recorded
  /// offset, not the phone's current zone), as a plain local DateTime so the
  /// plan's day maths compares like with like.
  static DateTime wallClock(RunSummary r) {
    final l = r.localStart;
    return DateTime(l.year, l.month, l.day, l.hour, l.minute, l.second);
  }

  static List<engine.PlanRun> runs(List<RunSummary> all) => [
    for (final r in all)
      if (!r.missing)
        engine.PlanRun(
          id: r.id,
          start: wallClock(r),
          movingMs: r.row?.movingMs ?? r.durationMs,
          distanceM: r.distanceM,
          kind: switch (r.mode) {
            RecordMode.cooper => engine.PlanRunKind.cooper,
            RecordMode.intervals when r.spec?.isGoal != true =>
              engine.PlanRunKind.intervals,
            _ => engine.PlanRunKind.other,
          },
          templateId: r.mode == RecordMode.intervals
              ? (r.spec?.templateId ?? engine.SessionSpec.norwegian4x4Id)
              : null,
          truePaceSecPerKm: r.truePaceSecPerKm,
        ),
  ];
}

/// The settings change that presets Start for a planned session.
abstract final class PlanStart {
  static AppSettings Function(AppSettings) apply(engine.BlockSession s) {
    switch (s.kind) {
      case engine.BlockKind.interval:
        final id = s.presetId!;
        return (a) => id == engine.SessionSpec.norwegian4x4Id
            ? a.copyWith(
                lastMode: RecordMode.intervals,
                goalRun: false,
                sessionId: id,
                reps: PresetRules.clampReps(s.reps ?? a.reps),
              )
            : a.copyWith(
                lastMode: RecordMode.intervals,
                goalRun: false,
                sessionId: id,
                presetEdits: {
                  ...a.presetEdits,
                  id: PresetEdit(
                    reps: s.reps,
                    recovery: a.presetEdits[id]?.recovery,
                  ),
                },
              );
      case engine.BlockKind.goal:
        final goal = s.goalId ?? 'd5000';
        return (a) => a.copyWith(goalRun: true, goalId: goal);
      case engine.BlockKind.easy:
      case engine.BlockKind.long:
        return (a) => a.copyWith(lastMode: RecordMode.free, goalRun: false);
    }
  }
}

/// Runs and scores as the plan sees them; the one place the view is made.
class PlanContext {
  PlanContext({required this.runs, required this.scores, required this.now});
  final List<RunSummary> runs;
  final Map<engine.IdentityLane, engine.IdentityScore> scores;
  final DateTime now;

  late final List<engine.PlanRun> planRuns = PlanInputs.runs(runs);
  late final engine.BlockBaseline baseline = engine.BlockBaselines.of(
    planRuns,
    scores,
    now: now,
  );

  double? get vdot => baseline.vdot;

  engine.BlockView? view(engine.BlockPlan? plan) => plan == null
      ? null
      : engine.BlockResolver.resolve(plan, planRuns, now: now, vdot: vdot);
}

/// Every line the plan shows, so the wording lives in one place.
abstract final class PlanText {
  static String dayWord(DateTime date, DateTime now) =>
      engine.dateOnly(date).isAfter(engine.dateOnly(now))
      ? engine.BlockResolver.dayName(date)
      : 'today';

  /// "This week: 2 of 3 done · Next: Norwegian 4x4 Thu".
  static String homeLine(engine.BlockView v, DateTime now) {
    final n = v.next;
    if (v.finished || n == null) {
      return 'Your 4 weeks are done: ${v.doneCount} of ${v.totalCount} sessions.';
    }
    final when = '${n.session.name} ${dayWord(n.date, now)}';
    if (v.nextIsNextWeek) {
      return 'This week: ${v.weekDone} of ${v.weekTotal} done · Next week: $when';
    }
    return 'This week: ${v.weekDone} of ${v.weekTotal} done · Next: $when';
  }

  /// How hard to run it, in plain words. With a pace estimate it names the
  /// pace; with none (no scores yet, or a VDOT the pace model cannot place)
  /// it falls back to effort only, so the guidance never just disappears.
  static String targetLine(engine.BlockSession s, double? vdot, Units units) {
    final pace = engine.BlockPaces.target(s, vdot);
    if (pace == null) {
      return switch (s.kind) {
        engine.BlockKind.easy ||
        engine.BlockKind.long => 'Easy effort: you can talk in full sentences.',
        engine.BlockKind.goal =>
          'Run it as fast as you can hold. No pace estimate yet.',
        engine.BlockKind.interval =>
          'Hard but even effort. No pace estimate yet: a 5K or a 4x4 sets one.',
      };
    }
    final p = Fmt.paceUnit(pace, units);
    return switch (s.kind) {
      engine.BlockKind.easy ||
      engine.BlockKind.long => 'Easy pace: $p or slower (True Pace estimate).',
      engine.BlockKind.goal => 'Aim for about $p (True Pace estimate).',
      engine.BlockKind.interval =>
        'Work reps at about $p (True Pace estimate).',
    };
  }

  static String? weekTag(engine.BlockPlan plan, int week) {
    if (plan.sessions.any((s) => s.week == week && s.isTest)) {
      return 'TEST WEEK';
    }
    return engine.BlockPlanner.isLight(plan.lane, week) ? 'LIGHTER WEEK' : null;
  }

  static String shiftLine(int shifts) => shifts == 1
      ? 'A week went by with nothing done, so the plan moved back a week.'
      : 'Weeks went by with nothing done, so the plan moved back $shifts weeks.';
}
