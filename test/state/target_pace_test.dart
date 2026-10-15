import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:run_engine/run_engine.dart' as engine;
import 'package:run_solo/platform/gateway.dart';
import 'package:run_solo/state/history_store.dart';
import 'package:run_solo/state/run_index.dart';
import 'package:run_solo/state/target_pace.dart';
import 'package:run_solo/state/zone_histogram.dart';

void main() {
  final now = DateTime(2026, 10, 15, 9);
  DateTime daysAgo(int d) => DateTime(now.year, now.month, now.day - d, 12);
  final zones = engine.HrZones.percentMax(190);

  // 110 bpm sits in zone 1, 150 in zone 4 (percent of max HR 190).
  HrHist hist({required int easySecs, required int hardSecs}) =>
      HrHist(110, [easySecs, for (var i = 0; i < 39; i++) 0, hardSecs]);

  RunSummary easy(
    String id,
    int back,
    double pace, {
    HrHist? hr,
    RecordMode? m,
  }) => RunSummary(
    id: id,
    mode: m ?? RecordMode.free,
    start: daysAgo(back),
    durationMs: 40 * 60 * 1000,
    distanceM: 7000,
    laps: 1,
    row: IndexRow(lapCount: 1, truePaceSecPerKm: pace),
    hrHist: hr ?? hist(easySecs: 2000, hardSecs: 400),
  );

  RunSummary set(String id, int back, String template, double workTrue) =>
      RunSummary(
        id: id,
        mode: RecordMode.intervals,
        start: daysAgo(back),
        durationMs: 40 * 60 * 1000,
        distanceM: 7000,
        laps: 8,
        spec: engine.SessionCatalogue.byId(template)!.defaults,
        row: IndexRow(lapCount: 8, workTruePaceSecPerKm: workTrue),
      );

  group('evidence', () {
    test('easy runs need a strap and mostly zone 1 to 2', () {
      final ev = paceEvidence([
        easy('a', 2, 330),
        easy('b', 4, 330, hr: hist(easySecs: 600, hardSecs: 2000)),
        RunSummary(
          id: 'c',
          mode: RecordMode.free,
          start: daysAgo(6),
          durationMs: 2400000,
          distanceM: 7000,
          laps: 1,
          row: const IndexRow(lapCount: 1, truePaceSecPerKm: 330),
        ),
      ], zones: zones);
      expect(ev[engine.PaceIntensity.easy]!.map((o) => o.runId), ['a']);
    });

    test('a trail run counts at its true pace', () {
      final ev = paceEvidence([
        easy('t', 3, 350, m: RecordMode.trail),
      ], zones: zones);
      expect(ev[engine.PaceIntensity.easy]!.single.trueSecPerKm, 350);
    });

    test('4x4 reps are VO2 max, tempo reps are tempo', () {
      final ev = paceEvidence([
        set('v', 3, engine.SessionSpec.norwegian4x4Id, 255),
        set('t', 5, 'tempo', 300),
        set('y', 9, 'yasso-800s', 280),
      ], zones: zones);
      expect(ev[engine.PaceIntensity.vo2max]!.single.trueSecPerKm, 255);
      expect(ev[engine.PaceIntensity.tempo]!.single.trueSecPerKm, 300);
      expect(
        [for (final l in ev.values) ...l].map((o) => o.runId),
        isNot(contains('y')),
      );
    });
  });

  group('controller', () {
    final paces = engine.TargetPaces.fromVdot(40)!;
    final easyTarget = paces[engine.PaceIntensity.easy]!.trueSecPerKm;
    List<engine.PaceObservation> quicker(double pace) => [
      for (final d in [2, 9, 15, 22])
        engine.PaceObservation(
          runId: 'r$d',
          date: daysAgo(d),
          trueSecPerKm: pace,
        ),
    ];

    test(
      'asking for a nudge changes nothing; only accept moves a target',
      () async {
        final store = MemoryTargetPaceStore();
        final c = TargetPaceController(store);
        final ev = {engine.PaceIntensity.easy: quicker(easyTarget - 15)};
        final n = c.nudge(paces, ev, now: now);
        expect(n, isNotNull);
        expect(n!.intensity, engine.PaceIntensity.easy);
        // Asked twice, rebuilt, listened to: still nothing adopted.
        c.nudge(paces, ev, now: now);
        expect(c.adopted, isEmpty);
        expect(store.state.adopted, isEmpty);
        await c.accept(n, now: now);
        expect(c.adopted[engine.PaceIntensity.easy], n.toSecPerKm);
        expect(store.state.adopted[engine.PaceIntensity.easy], n.toSecPerKm);
      },
    );

    test('keep leaves the target and goes quiet for three weeks', () async {
      final c = TargetPaceController(MemoryTargetPaceStore());
      final ev = {engine.PaceIntensity.easy: quicker(easyTarget - 15)};
      final n = c.nudge(paces, ev, now: now)!;
      await c.keep(n, now: now);
      expect(c.adopted, isEmpty);
      expect(c.nudge(paces, ev, now: now), isNull);
      expect(
        c.nudge(paces, ev, now: now.add(const Duration(days: 22))),
        isNull,
        reason: 'the old runs are spent evidence',
      );
    });

    test('undo goes back to the tables', () async {
      final c = TargetPaceController(MemoryTargetPaceStore());
      final n = c.nudge(paces, {
        engine.PaceIntensity.easy: quicker(easyTarget - 15),
      }, now: now)!;
      await c.accept(n, now: now);
      await c.reset(engine.PaceIntensity.easy);
      expect(c.adopted, isEmpty);
    });

    test('the file survives a restart and shrugs off damage', () async {
      final dir = await Directory.systemTemp.createTemp('target_paces');
      addTearDown(() => dir.delete(recursive: true));
      final c = TargetPaceController(FileTargetPaceStore(dir));
      final n = c.nudge(paces, {
        engine.PaceIntensity.easy: quicker(easyTarget - 15),
      }, now: now)!;
      await c.accept(n, now: now);
      final back = TargetPaceController(FileTargetPaceStore(dir));
      await back.load();
      expect(back.adopted[engine.PaceIntensity.easy], n.toSecPerKm);
      expect(back.state.answers[engine.PaceIntensity.easy]!.accepted, isTrue);
      File('${dir.path}/target_paces.json').writeAsStringSync('{not json');
      final broken = TargetPaceController(FileTargetPaceStore(dir));
      await broken.load();
      expect(broken.adopted, isEmpty);
      expect(
        TargetPaceState.tryParse(jsonDecode('{"adopted":{"easy":-4,"x":9}}'))
            .adopted,
        isEmpty,
      );
    });

    test('a failed save puts the old pace back and says so', () async {
      final c = TargetPaceController(_FailingStore());
      final n = c.nudge(paces, {
        engine.PaceIntensity.easy: quicker(easyTarget - 15),
      }, now: now)!;
      await expectLater(c.accept(n, now: now), throwsStateError);
      expect(c.adopted, isEmpty);
      expect(c.state.answers, isEmpty);
    });

    test('accepting remembers the tables so the move can lapse', () async {
      final c = TargetPaceController(MemoryTargetPaceStore());
      final n = c.nudge(paces, {
        engine.PaceIntensity.easy: quicker(easyTarget - 15),
      }, now: now)!;
      await c.accept(n, now: now, modelSecPerKm: easyTarget);
      expect(c.adoptedFrom[engine.PaceIntensity.easy], easyTarget);
      await c.reset(engine.PaceIntensity.easy);
      expect(c.adoptedFrom, isEmpty);
    });
  });
}

class _FailingStore implements TargetPaceStore {
  @override
  Future<TargetPaceState> load() async => TargetPaceState.empty;

  @override
  Future<void> save(TargetPaceState state) async =>
      throw StateError('disk full');
}
