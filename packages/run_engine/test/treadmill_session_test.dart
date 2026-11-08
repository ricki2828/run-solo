import 'package:run_engine/run_engine.dart';
import 'package:test/test.dart';

/// 7-Nov: a session (the 12-minute test, intervals) run on a treadmill. The
/// mode stays the session's own; the run carries an incline and a typed-in
/// distance, and has no GPS.
RunFile belt({
  RunMode mode = RunMode.cooper,
  double? incline = 1,
  double? distance = 2800,
  int endS = 1300,
  List<Span> pauses = const [],
}) {
  final cooper = mode == RunMode.cooper;
  return RunFile(
    id: '00000000-0000-4000-8000-0000000000cd',
    device: 'phone',
    app: 'test',
    start: DateTime.utc(2026, 11, 7, 6),
    end: DateTime.utc(2026, 11, 7, 6).add(Duration(seconds: endS)),
    tz: 'UTC',
    mode: mode,
    session: cooper ? SessionSpec.cooper : SessionSpec.norwegian4x4(),
    units: Units.km,
    laps: [
      // Warm-up 5:00 ended by BEGIN TEST, the 12:00 test, the cool-down.
      const Lap(
        index: 0,
        t0Ms: 0,
        t1Ms: 300000,
        d0M: 0,
        d1M: 0,
        kind: LapKind.manual,
      ),
      const Lap(
        index: 1,
        t0Ms: 300000,
        t1Ms: 1020000,
        d0M: 0,
        d1M: 0,
        kind: LapKind.auto,
      ),
      Lap(
        index: 2,
        t0Ms: 1020000,
        t1Ms: endS * 1000,
        d0M: 0,
        d1M: 0,
        kind: LapKind.manual,
      ),
    ],
    pauses: pauses,
    treadmillDistanceM: distance,
    treadmillInclinePct: incline,
    samples: [
      for (var i = 0; i <= endS; i++)
        Sample(
          tMs: i * 1000,
          lat: null,
          lon: null,
          altM: null,
          accM: null,
          speedMps: null,
          distM: 0,
          hr: 150,
        ),
    ],
  );
}

CooperResult cooperOf(RunFile run) =>
    CooperResult.of(run, indoor: true, noisy: false);

void main() {
  group('file', () {
    test('incline and distance round trip on a Cooper run, schema 9', () {
      final run = belt();
      expect(run.onTreadmill, isTrue);
      expect(run.writeSchema, 9);
      final json = run.toJson();
      expect(json['mode'], 'cooper');
      expect(json['treadmillInclinePct'], 1.0);
      final back = RunFile.fromJson(json);
      expect(back.mode, RunMode.cooper);
      expect(back.treadmillInclinePct, 1.0);
      expect(back.treadmillDistanceM, 2800);
      expect(RunFileCodec.encode(back), RunFileCodec.encode(run));
    });

    test('intervals carry the surface too, with markers', () {
      final json = belt(mode: RunMode.intervals, distance: 5000).toJson();
      json['treadmillMarks'] = [
        [180000, 500.0],
      ];
      final run = RunFile.fromJson(json);
      expect(run.mode, RunMode.intervals);
      expect(run.treadmillMarks.single.distanceM, 500);
    });

    test('a file without the key is not on a treadmill and still loads', () {
      final json = belt(incline: null, distance: null).toJson();
      expect(json.containsKey('treadmillInclinePct'), isFalse);
      final run = RunFile.fromJson(json);
      expect(run.onTreadmill, isFalse);
      expect(run.writeSchema, RunFile.phoneSchema);
    });

    test('a free treadmill run is on the belt without the key', () {
      final free = RunFile(
        id: '00000000-0000-4000-8000-0000000000ce',
        device: 'phone',
        app: 'test',
        start: DateTime.utc(2026, 11, 7),
        end: DateTime.utc(2026, 11, 7, 0, 1),
        tz: 'UTC',
        mode: RunMode.treadmill,
        units: Units.km,
        laps: const [],
        treadmillDistanceM: 1000,
        samples: const [],
      );
      expect(free.onTreadmill, isTrue);
      expect(free.treadmillInclinePct, isNull);
      expect(RunFile.fromJson(free.toJson()).treadmillDistanceM, 1000);
    });

    test('a typed-in distance on an outdoor run is refused', () {
      final json = belt(incline: null, distance: null).toJson()
        ..['treadmillDistanceM'] = 2800.0;
      expect(
        () => RunFile.fromJson(json),
        throwsA(isA<RunFileFormatException>()),
      );
    });

    test('a nonsense incline is refused', () {
      for (final bad in <Object?>[-1, 40, 'x', double.nan]) {
        final json = belt().toJson()..['treadmillInclinePct'] = bad;
        expect(
          () => RunFile.fromJson(json),
          throwsA(isA<RunFileFormatException>()),
          reason: '$bad',
        );
      }
    });

    test('the incline needs schema 9', () {
      final json = belt().toJson()..['schema'] = 7;
      expect(
        () => RunFile.fromJson(json),
        throwsA(isA<RunFileFormatException>()),
      );
    });

    test('copyWith keeps the surface', () {
      final run = belt().copyWith(id: '00000000-0000-4000-8000-0000000000cf');
      expect(run.treadmillInclinePct, 1.0);
      expect(run.treadmillDistanceM, 2800);
    });
  });

  group('12-minute test on a belt', () {
    test('the typed distance gives the estimate, tagged', () {
      final c = cooperOf(belt());
      expect(c.valid, isTrue);
      expect(c.onTreadmill, isTrue);
      expect(c.testDistanceM, 2800);
      expect(c.minuteM, isNull);
      expect(c.heat, isNull);
      expect(c.estimate!.vo2, closeTo((2800 - 504.9) / 44.73, 1e-9));
      expect(c.primeVo2, c.estimate!.vo2);
      expect(c.treadmillTag, 'Treadmill · 1%');
    });

    test('the top chip reads 3+', () {
      expect(cooperOf(belt(incline: 3)).treadmillTag, 'Treadmill · 3+%');
      expect(cooperOf(belt(incline: 0)).treadmillTag, 'Treadmill · 0%');
    });

    test('stopped early, paused, or no distance: no estimate', () {
      expect(cooperOf(belt(endS: 900)).invalid, CooperInvalid.short);
      expect(
        cooperOf(belt(pauses: const [Span(600000, 620000)])).invalid,
        CooperInvalid.paused,
      );
      final none = cooperOf(belt(distance: null));
      expect(none.invalid, CooperInvalid.noDistance);
      expect(none.invalidLine, contains('No distance'));
      expect(none.estimate, isNull);
    });

    test('a typed distance outside 800-5000 m is invalid, not a VO2', () {
      for (final d in [28000.0, 5001.0, 799.0, 0.0]) {
        final c = cooperOf(belt(distance: d));
        expect(c.invalid, CooperInvalid.implausible, reason: '$d');
        expect(c.estimate, isNull);
        expect(c.invalidLine, contains('not possible'));
      }
      expect(cooperOf(belt(distance: 800)).valid, isTrue);
      expect(cooperOf(belt(distance: 5000)).valid, isTrue);
    });

    test('an outdoor test is untouched', () {
      final c = CooperResult.of(
        belt(incline: null, distance: null),
        indoor: true,
        noisy: false,
      );
      expect(c.onTreadmill, isFalse);
      expect(c.invalid, CooperInvalid.indoor);
    });
  });

  group('analysis', () {
    test('a Cooper belt run is indoor, keeps its mode, has no weather', () {
      final a = const RunEngine().analyze(
        belt(),
        now: DateTime.utc(2026, 11, 7, 7),
      );
      expect(a.mode, RunMode.cooper);
      expect(a.indoor, isTrue);
      expect(a.truePace, isNull);
      expect(a.weather, isNull);
      expect(a.cooper!.valid, isTrue);
      expect(a.cooper!.treadmillInclinePct, 1.0);
    });

    test('an intervals belt run is indoor and gets no pace verdict', () {
      final a = const RunEngine().analyze(
        belt(mode: RunMode.intervals, distance: null),
        now: DateTime.utc(2026, 11, 7, 7),
      );
      expect(a.mode, RunMode.intervals);
      expect(a.indoor, isTrue);
      expect(a.eligibleAsPrior, isFalse);
      expect(a.verdict?.headline, anyOf(isNull, VerdictHeadline.indoorRun));
    });

    test('a belt run has no best efforts and no km splits', () {
      final run = belt(mode: RunMode.intervals, distance: 5200);
      final a = const RunEngine().analyze(run, now: DateTime.utc(2026, 11, 7));
      expect(const BestEffortFinder().find(run, a).efforts, isEmpty);
      expect(kmSplitWindows(run), isEmpty);
    });
  });

  group('distance goal on a belt', () {
    RunFile goalRun({required List<Lap> laps, double? distance}) => belt(
      mode: RunMode.intervals,
      distance: distance,
      endS: 1700,
    ).copyWith(session: SessionSpec.goalDistance(5000, '5K'), laps: laps);

    const l0 = Lap(
      index: 0,
      t0Ms: 0,
      t1Ms: 1500000,
      d0M: 0,
      d1M: 0,
      kind: LapKind.manual,
    );
    const l1 = Lap(
      index: 1,
      t0Ms: 1500000,
      t1Ms: 1700000,
      d0M: 0,
      d1M: 0,
      kind: LapKind.manual,
    );

    test('a GOAL DONE tap is the goal reached, its time the tap', () {
      final g = GoalResult.of(
        goalRun(laps: const [l0, l1]),
        SessionSpec.goalDistance(5000, '5K'),
      )!;
      expect(g.reached, isTrue);
      expect(g.goalMs, 1500000);
      expect(g.resultLine, '5K in 25:00');
      expect(g.stoppedAtM, 5000);
    });

    test('a pause before the tap is not goal time', () {
      final run = goalRun(laps: const [l0, l1]);
      final paused = run.copyWith(pauses: const [Span(600000, 660000)]);
      final g = GoalResult.of(paused, SessionSpec.goalDistance(5000, '5K'))!;
      expect(g.goalMs, 1500000 - 60000);
    });

    test('stopped before the tap: not reached, the typed distance shows', () {
      final g = GoalResult.of(
        goalRun(laps: const [l0], distance: 3200),
        SessionSpec.goalDistance(5000, '5K'),
      )!;
      expect(g.reached, isFalse);
      expect(g.stoppedAtM, 3200);
    });
  });
}
