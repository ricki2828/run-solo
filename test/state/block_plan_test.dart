import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:run_engine/run_engine.dart' as engine;
import 'package:run_solo/platform/gateway.dart';
import 'package:run_solo/state/block_plan.dart';
import 'package:run_solo/state/history_store.dart';
import 'package:run_solo/state/run_index.dart';
import 'package:run_solo/state/sessions.dart';
import 'package:run_solo/state/settings.dart';

import '../run_fixtures.dart';

void main() {
  late Directory dir;
  setUp(() async => dir = await Directory.systemTemp.createTemp('plan-'));
  tearDown(() => dir.delete(recursive: true));

  engine.BlockPlan plan0() => engine.BlockPlanner.build(
    lane: engine.IdentityLane.speed,
    perWeek: 4,
    start: DateTime(2026, 10, 5),
  );

  group('store', () {
    test('file round trip, then clear', () async {
      final store = FileBlockPlanStore(dir);
      expect(await store.load(), isNull);
      final p = plan0();
      await store.save(p);
      expect((await store.load())!.toJson(), p.toJson());
      await store.save(null);
      expect(await store.load(), isNull);
      expect(store.file.existsSync(), isFalse);
    });

    test('a damaged or newer file reads as no plan', () async {
      final store = FileBlockPlanStore(dir);
      await store.file.writeAsString('{not json');
      expect(await store.load(), isNull);
      await store.file.writeAsString('{"schema": 99}');
      expect(await store.load(), isNull);
    });
  });

  group('controller', () {
    test('create, swap one session, end', () async {
      final c = BlockPlanController(FileBlockPlanStore(dir));
      var ticks = 0;
      c.addListener(() => ticks++);
      await c.create(plan0());
      final first = c.plan!.sessions.first;
      final alt = engine.BlockPlanner.alternatives(first).first;
      await c.swap(alt);
      expect(c.plan!.sessions.first.swapped, isTrue);
      expect(c.plan!.sessions[1].toJson(), plan0().sessions[1].toJson());
      final back = BlockPlanController(FileBlockPlanStore(dir));
      await back.load();
      expect(back.plan!.sessions.first.swapped, isTrue);
      await c.end();
      expect(c.plan, isNull);
      expect(ticks, 3);
      await back.load();
      expect(back.plan, isNull);
    });
  });

  group('Start preset', () {
    test('4x4 sets reps; other presets set their own edit', () {
      final p = engine.BlockPlanner.build(
        lane: engine.IdentityLane.aerobic,
        perWeek: 4,
        start: DateTime(2026, 10, 5),
      );
      final four = p.sessions.firstWhere(
        (s) => s.week == 3 && s.role == engine.BlockRole.key,
      );
      final a = PlanStart.apply(four)(const AppSettings());
      expect(a.sessionId, engine.SessionSpec.norwegian4x4Id);
      expect(a.reps, 5);
      expect(a.goalRun, isFalse);
      final tempo = p.sessions.firstWhere((s) => s.presetId == 'tempo');
      final b = PlanStart.apply(tempo)(const AppSettings());
      expect(b.sessionId, 'tempo');
      expect(b.presetEdits['tempo']!.reps, tempo.reps);
      final easy = p.sessions.firstWhere(
        (s) => s.kind == engine.BlockKind.easy,
      );
      final c = PlanStart.apply(easy)(const AppSettings(goalRun: true));
      expect(c.lastMode, RecordMode.free);
      expect(c.goalRun, isFalse);
      final mid = engine.BlockPlanner.build(
        lane: engine.IdentityLane.mid,
        perWeek: 2,
        start: DateTime(2026, 10, 5),
      ).sessions.firstWhere((s) => s.isTest);
      final d = PlanStart.apply(mid)(const AppSettings());
      expect(d.goalRun, isTrue);
      expect(d.goalId, 'd5000');
    });
  });

  group('from History (FileRunStore, index rows only)', () {
    test('real runs tick the plan and size the baseline', () async {
      final d1 = DateTime(2026, 10, 5, 6);
      final store = FileRunStore(
        Directory('${dir.path}/runs'),
        profile: () => const engine.UserProfile(age: 40),
      );
      store.deriveBatch = FileRunStore.deriveInIsolate;
      await store.importBundles([
        engine.RunBundle(run: fourByFourFile(n: 1, start: d1)),
        engine.RunBundle(
          run: freeRunFile(n: 2, start: d1.add(const Duration(days: 1))),
        ),
      ]);
      final rows = await store.list();
      await store.derivedIdle;
      expect(rows.every((r) => r.analysis == null), isTrue);
      final ctx = PlanContext(
        runs: rows,
        scores: const {},
        now: d1.add(const Duration(days: 2)),
      );
      final kinds = {for (final r in ctx.planRuns) r.id: r.kind};
      expect(kinds.values, contains(engine.PlanRunKind.intervals));
      expect(kinds.values, contains(engine.PlanRunKind.other));
      expect(ctx.planRuns.every((r) => r.movingMs > 0), isTrue);
      final plan = engine.BlockPlanner.build(
        lane: engine.IdentityLane.aerobic,
        perWeek: 3,
        start: DateTime(2026, 10, 5),
      );
      final view = ctx.view(plan)!;
      expect(view.weeks[0][0].status, engine.BlockStatus.done);
      expect(view.weekDone, greaterThanOrEqualTo(1));
      await store.derivedIdle;
    });
  });

  group('dates are the runner\'s own wall clock', () {
    RunSummary run(String id, DateTime startUtc, int? offsetMin) => RunSummary(
      id: id,
      mode: RecordMode.intervals,
      start: startUtc,
      durationMs: 2400000,
      distanceM: 6000,
      laps: 4,
      utcOffsetMin: offsetMin,
      row: const IndexRow(lapCount: 4, movingMs: 2400000),
    );

    test('an SGT 6am run stored as UTC lands on its own Monday', () {
      // 22:00 UTC on Sunday 4 Oct is 06:00 Monday 5 Oct in Singapore.
      final sgt = run('sgt', DateTime.utc(2026, 10, 4, 22), 480);
      final w = PlanInputs.wallClock(sgt);
      expect([w.year, w.month, w.day, w.hour], [2026, 10, 5, 6]);
      expect(w.isUtc, isFalse);
      final plan = engine.BlockPlanner.build(
        lane: engine.IdentityLane.aerobic,
        perWeek: 3,
        start: DateTime(2026, 10, 5),
      );
      final ctx = PlanContext(
        runs: [sgt],
        scores: const {},
        now: DateTime(2026, 10, 5, 12),
      );
      expect(ctx.view(plan)!.weekDone, 1);
    });

    test(
      'a run before the recorded offset existed falls back to the phone',
      () {
        final r = run('old', DateTime.utc(2026, 10, 5, 3), null);
        final w = PlanInputs.wallClock(r);
        expect(w, DateTime.utc(2026, 10, 5, 3).toLocal());
      },
    );
  });

  group('Start preset keeps saved edits', () {
    test('a saved recovery edit survives the plan setting the reps', () {
      final rec = engine.SessionStep.recoveryDistance(300, rep: 1);
      final s = AppSettings(
        presetEdits: {'400s': PresetEdit(reps: 12, recovery: rec)},
      );
      final plan = engine.BlockPlanner.build(
        lane: engine.IdentityLane.speed,
        perWeek: 3,
        start: DateTime(2026, 10, 5),
      );
      final key = plan.sessions.first;
      final a = PlanStart.apply(key)(s);
      expect(a.presetEdits['400s']!.reps, key.reps);
      expect(a.presetEdits['400s']!.recovery, rec);
      final other = AppSettings(presetEdits: {'tempo': PresetEdit(reps: 4)});
      expect(PlanStart.apply(key)(other).presetEdits['tempo']!.reps, 4);
    });
  });

  group('text', () {
    final p = plan0();
    test('home line, today, next week and finished', () {
      final start = DateTime(2026, 10, 5);
      var v = engine.BlockResolver.resolve(p, [], now: start);
      expect(
        PlanText.homeLine(v, start),
        'This week: 0 of 4 done · Next: 6 × 400 m today',
      );
      v = engine.BlockResolver.resolve(
        p,
        [],
        now: start.subtract(const Duration(days: 3)),
      );
      expect(v.currentWeek, 1);
      v = engine.BlockResolver.resolve(
        p,
        [],
        now: start.add(const Duration(days: 90)),
      );
      expect(
        PlanText.homeLine(v, start),
        'Your 4 weeks are done: 0 of 16 sessions.',
      );
    });

    test('target line labels the pace an estimate; none without a VDOT', () {
      final rep = p.sessions.first;
      // No estimate: effort-only guidance, never nothing.
      final fallback = PlanText.targetLine(rep, null, Units.km);
      expect(fallback, contains('No pace estimate yet'));
      expect(fallback, isNot(contains('/km')));
      final easy = p.sessions.firstWhere(
        (s) => s.kind == engine.BlockKind.easy,
      );
      expect(
        PlanText.targetLine(easy, null, Units.km),
        contains('full sentences'),
      );
      final line = PlanText.targetLine(rep, 45, Units.km);
      expect(line, contains('estimate'));
      expect(line, contains('/km'));
    });

    test('week tags and no em dashes anywhere', () {
      expect(PlanText.weekTag(p, 4), 'TEST WEEK');
      expect(PlanText.weekTag(p, 2), isNull);
      expect(PlanText.weekTag(plan0(), 1), isNull);
      expect(PlanText.shiftLine(1), isNot(contains('—')));
      expect(PlanText.shiftLine(2), contains('2 weeks'));
    });
  });
}
