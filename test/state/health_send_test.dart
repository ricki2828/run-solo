import 'package:flutter_test/flutter_test.dart';
import 'package:run_engine/run_engine.dart' as engine;
import 'package:run_solo/platform/health_gateway.dart';
import 'package:run_solo/platform/platform_api.g.dart';
import 'package:run_solo/state/health_workout.dart';
import 'package:run_solo/state/history_store.dart';
import 'package:run_solo/state/send_runs.dart';
import 'package:run_solo/state/settings.dart';

import '../helpers.dart';
import '../run_fixtures.dart';

void main() {
  final start = DateTime.utc(2026, 10, 2, 6);
  late engine.RunFile run;

  setUp(() => run = fourByFourFile(n: 1, start: start));

  HealthWorkout build({int version = 1}) => HealthWorkoutBuilder.build(
    run,
    title: 'Morning run',
    utcOffsetSeconds: 36000,
    version: version,
  );

  group('record mapping', () {
    test('session: id, times, offset, distance', () {
      final w = build();
      expect(w.clientRecordId, run.id);
      expect(w.startEpochMs, run.start.millisecondsSinceEpoch);
      expect(w.endEpochMs, run.end.millisecondsSinceEpoch);
      expect(w.utcOffsetSeconds, 36000);
      expect(w.distanceM, run.distanceM);
      expect(w.title, 'Morning run');
    });

    test('laps carry their span and distance, pauses are not laps', () {
      final w = build();
      final real = run.laps.where((l) => l.kind != engine.LapKind.pause);
      expect(w.laps.length, real.length);
      final first = real.first;
      expect(
        w.laps.first.startEpochMs,
        run.start.millisecondsSinceEpoch + first.t0Ms,
      );
      expect(w.laps.first.distanceM, closeTo(first.distanceM, 1e-6));
    });

    test('pauses become pause spans inside the session', () {
      final paused = run.copyWith(pauses: [const engine.Span(60000, 90000)]);
      final w = HealthWorkoutBuilder.build(
        paused,
        title: 't',
        utcOffsetSeconds: 0,
        version: 1,
      );
      expect(
        w.pauses.single.startEpochMs,
        paused.start.millisecondsSinceEpoch + 60000,
      );
      expect(
        w.pauses.single.endEpochMs,
        paused.start.millisecondsSinceEpoch + 90000,
      );
    });

    test('touching and overlapping pauses are merged, unsorted input too', () {
      final paused = run.copyWith(
        pauses: [
          const engine.Span(50000, 70000),
          const engine.Span(10000, 20000),
          const engine.Span(20000, 25000),
          const engine.Span(15000, 22000),
          const engine.Span(60000, 65000),
        ],
      );
      final w = HealthWorkoutBuilder.build(
        paused,
        title: 't',
        utcOffsetSeconds: 0,
        version: 1,
      );
      final s = paused.start.millisecondsSinceEpoch;
      expect(
        [for (final p in w.pauses) (p.startEpochMs - s, p.endEpochMs - s)],
        [(10000, 25000), (50000, 70000)],
      );
    });

    test(
      'heart rate is thinned to one point per 5 s and keeps real values',
      () {
        final w = build();
        expect(w.hr, isNotEmpty);
        for (var i = 1; i < w.hr.length; i++) {
          expect(
            w.hr[i].epochMs - w.hr[i - 1].epochMs,
            greaterThanOrEqualTo(5000),
          );
        }
        final bpms = run.samples
            .where((s) => s.hr != null)
            .map((s) => s.hr)
            .toSet();
        expect(w.hr.every((h) => bpms.contains(h.bpm)), isTrue);
      },
    );

    test('route is thinned and leaves out the first and last 200 m', () {
      final w = build();
      expect(w.route, isNotEmpty);
      final byTime = {
        for (final s in run.samples)
          run.start.millisecondsSinceEpoch + s.tMs: s,
      };
      for (final p in w.route) {
        final s = byTime[p.epochMs]!;
        expect(s.distM, greaterThanOrEqualTo(200));
        expect(run.distanceM - s.distM, greaterThanOrEqualTo(200));
        expect(p.lat, s.lat);
      }
      for (var i = 1; i < w.route.length; i++) {
        expect(
          w.route[i].epochMs - w.route[i - 1].epochMs,
          greaterThanOrEqualTo(5000),
        );
      }
    });

    test('a run with no fixes has no route; a run without HR has no HR', () {
      final bare = run.copyWith(
        samples: [
          for (final s in run.samples)
            s.copyWith(lat: null, lon: null, hr: null),
        ],
      );
      final w = HealthWorkoutBuilder.build(
        bare,
        title: 't',
        utcOffsetSeconds: 0,
        version: 1,
      );
      expect(w.route, isEmpty);
      expect(w.hr, isEmpty);
    });

    test('laps and pauses past the end are clamped or dropped', () {
      final w = HealthWorkoutBuilder.build(
        run.copyWith(
          pauses: [engine.Span(run.elapsedMs + 5000, run.elapsedMs + 9000)],
        ),
        title: 't',
        utcOffsetSeconds: 0,
        version: 1,
      );
      expect(w.pauses, isEmpty);
      expect(w.laps.every((l) => l.endEpochMs <= w.endEpochMs), isTrue);
    });
  });

  group('HealthTarget', () {
    final now = DateTime.utc(2026, 10, 2, 8);
    SendRequest req() =>
        SendRequest(run: run, title: 'Morning run', utcOffsetMin: 600);
    HealthTarget target(FakeHealthGateway g) =>
        HealthTarget(gateway: g, now: () => now, ios: false);

    test(
      'writes once with the run id as the record id and the phone offset',
      () async {
        final g = FakeHealthGateway();
        final r = await target(g).send(req());
        expect(r.ok, isTrue);
        expect(g.written.single.clientRecordId, run.id);
        expect(g.written.single.utcOffsetSeconds, 36000);
        expect(g.written.single.version, now.millisecondsSinceEpoch);
      },
    );

    test(
      'a re-send carries the same id and a higher version (upsert)',
      () async {
        final g = FakeHealthGateway();
        var t = now;
        final tg = HealthTarget(gateway: g, now: () => t, ios: false);
        await tg.send(req());
        t = t.add(const Duration(minutes: 5));
        await tg.send(req());
        expect(g.written.map((w) => w.clientRecordId).toSet(), {run.id});
        expect(g.written[1].version, greaterThan(g.written[0].version));
      },
    );

    test('permission denied: nothing written, state says so', () async {
      final g = FakeHealthGateway(coreGranted: false);
      final r = await target(g).send(req());
      expect(r.ok, isFalse);
      expect(r.error, contains('access is off'));
      expect(g.written, isEmpty);
    });

    test('route permission missing still sends the run', () async {
      final g = FakeHealthGateway(routeGranted: false)
        ..outcome = HealthWriteOutcome.writtenWithoutRoute;
      expect((await target(g).send(req())).ok, isTrue);
    });

    test(
      'not installed / needs update / unsupported explain themselves',
      () async {
        for (final a in [
          HealthAvailability.notInstalled,
          HealthAvailability.needsUpdate,
          HealthAvailability.unsupported,
        ]) {
          final g = FakeHealthGateway(availability: a);
          final r = await target(g).send(req());
          expect(r.ok, isFalse, reason: '$a');
          expect(g.written, isEmpty);
          final setup = await target(g).prepare();
          expect(setup.isReady, isFalse);
          expect(
            setup.canInstall,
            a != HealthAvailability.unsupported,
            reason: '$a',
          );
        }
      },
    );

    test('write failures come back as a failed result', () async {
      final g = FakeHealthGateway(outcome: HealthWriteOutcome.failed);
      final r = await target(g).send(req());
      expect(r.ok, isFalse);
    });

    test('prepare asks for core, then route; refusing core blocks', () async {
      final g = FakeHealthGateway(coreGranted: false, routeGranted: false);
      expect((await target(g).prepare()).isReady, isTrue);
      expect(g.requests, [false, true]);
      final denied = FakeHealthGateway(
        coreGranted: false,
        grantCoreOnRequest: false,
      );
      final setup = await target(denied).prepare();
      expect(setup.isReady, isFalse);
      expect(denied.requests, [
        false,
      ], reason: 'no route prompt after a refusal');
    });

    test('route refused is not a blocker', () async {
      final g = FakeHealthGateway(
        routeGranted: false,
        grantRouteOnRequest: false,
      );
      expect((await target(g).prepare()).isReady, isTrue);
    });

    test('iOS shows Apple Health as coming soon', () {
      final t = HealthTarget(gateway: FakeHealthGateway(), ios: true);
      expect(t.label, 'Apple Health');
      expect(t.comingSoon, isTrue);
    });
  });

  test('automatic: a run after the enable time goes to Health, once', () async {
    final g = FakeHealthGateway();
    final store = MemoryRunStore(files: [run], now: now);
    final settings = SettingsController(
      MemorySettingsStore(),
      AppSettings(
        autoSend: const {'health'},
        autoSendSince: {'health': DateTime.utc(2026, 1, 1)},
      ),
    );
    final c = SendCoordinator(
      history: store,
      settings: settings,
      targets: [HealthTarget(gateway: g, now: now, ios: false)],
      now: now,
    );
    await c.sendAuto(run.id);
    await c.sendAuto(run.id);
    expect(g.written.length, 1);
    expect(store.sidecars[run.id]!.sends['health']!.ok, isTrue);
  });
}
