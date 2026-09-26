import 'dart:convert';

import 'package:run_engine/run_engine.dart';
import 'package:run_engine/testing.dart';
import 'package:test/test.dart';

import 'helpers.dart';

/// Phase 3 K1 (engine half): a single-lap parkrun gets a verdict, course
/// auto-tagging by start point, `parkrun:<courseId>` keys, the official time
/// in the sidecar, and flavour event names in every verdict string.
void main() {
  final day0 = DateTime.utc(2026, 9, 5, 22);
  const dogfood = EventNames(parkrun: 'parkrun');
  const play = EventNames(parkrun: '5K time trial');
  final spec = SessionSpec.parkrun(dogfood.parkrun);

  /// A 5 km at [mps] from the Start press, optionally with a warm-up (then
  /// the recorder's LAP boundary exists) and a jog after the finish.
  RunFile parkrun({
    int n = 1,
    double mps = 3.6,
    int warmupSeconds = 0,
    int cooldownSeconds = 0,
    LapStyle laps = LapStyle.auto,
    double latShiftDeg = 0,
    double? distanceM,
  }) {
    final secs = ((distanceM ?? 5000) / mps).round();
    final run = generator
        .generate(
          SyntheticSpec(
            name: 'k1_$n',
            id: '00000000-0000-4000-8000-${(7000 + n).toString().padLeft(12, '0')}',
            session: spec,
            lapStyle: laps,
            segments: [
              if (warmupSeconds > 0) Segment.warmup(warmupSeconds, 2.8),
              Segment.work(secs, mps),
              if (cooldownSeconds > 0) Segment.cooldown(cooldownSeconds, 2.5),
            ],
            hr: true,
            start: day0.add(Duration(days: 7 * n)),
          ),
        )
        .run;
    if (latShiftDeg == 0) return run;
    return run.copyWith(
      samples: [
        for (final s in run.samples)
          s.copyWith(lat: s.lat == null ? null : s.lat! + latShiftDeg),
      ],
    );
  }

  RunAnalysis analyze(
    RunFile run, {
    RunSidecar? sidecar,
    List<PriorRun> priors = const [],
    EventNames names = dogfood,
  }) =>
      RunEngine(names: names)
          .analyze(run, sidecar: sidecar, priors: priors, now: fixedNow);

  group('single-lap parkrun gets a verdict (no warm-up LAP)', () {
    test('Start on the line, auto-stop at 5.00 km: one lap', () {
      final run = parkrun();
      final one = run.copyWith(
        laps: [
          Lap(
            index: 0,
            t0Ms: 0,
            t1Ms: run.elapsedMs,
            d0M: 0,
            d1M: run.distanceM,
            kind: LapKind.auto,
          ),
        ],
      );
      final a = analyze(one);
      expect(a.detection!.consistent, isTrue);
      expect(a.verdict!.headline, VerdictHeadline.baselineSet);
      expect(a.verdict!.subline, matches(RegExp(r'^Finish 23:\d\d\. ')));
    });

    test('no laps at all (imported): the 5 km from the start', () {
      final a = analyze(parkrun(cooldownSeconds: 120, laps: LapStyle.none));
      expect(a.detection!.consistent, isTrue);
      expect(a.verdict!.headline, VerdictHeadline.baselineSet);
      // 5000 m at 3.6 m/s = 1389 s; the jog after the finish is cool-down.
      expect(a.intervals!.avgRepSeconds, closeTo(1389, 3));
      expect(a.detection!.cooldown, hasLength(1));
    });

    test('any one-step session with a single lap is detected (pinned)', () {
      const oneK = SessionSpec(
        templateId: 'custom:1k',
        templateVersion: 1,
        name: '1 × 1 km',
        steps: [SessionStep.workDistance(1000, rep: 1)],
      );
      final run = generator
          .generate(
            SyntheticSpec(
              name: 'k1_one_k',
              id: '00000000-0000-4000-8000-000000007999',
              session: oneK,
              lapStyle: LapStyle.auto,
              segments: [Segment.work(250, 4.0)],
              hr: true,
              start: day0,
            ),
          )
          .run;
      final one = run.copyWith(
        laps: [
          Lap(
            index: 0,
            t0Ms: 0,
            t1Ms: run.elapsedMs,
            d0M: 0,
            d1M: run.distanceM,
            kind: LapKind.auto,
          ),
        ],
      );
      final a = analyze(one);
      expect(a.detection!.consistent, isTrue);
      expect(a.detection!.reps, hasLength(1));
      expect(a.verdict!.headline, VerdictHeadline.baselineSet);
      // A multi-step session still needs its laps.
      final eight = analyze(
        one.copyWith(session: SessionCatalogue.fourHundreds.defaults),
      );
      expect(eight.detection!.consistent, isFalse);
    });

    test('stopped short of 5 km: no verdict, as before', () {
      final a = analyze(parkrun(distanceM: 4000, laps: LapStyle.none));
      expect(a.verdict!.headline, VerdictHeadline.noVerdict);
    });

    test('the warm-up LAP path is unchanged', () {
      final a = analyze(parkrun(warmupSeconds: 300, cooldownSeconds: 120));
      expect(a.detection!.consistent, isTrue);
      expect(a.detection!.warmup, hasLength(1));
      expect(a.intervals!.avgRepSeconds, closeTo(1389, 3));
    });
  });

  group('course auto-tag (start within 150 m)', () {
    final home = parkrun(n: 1);
    final start = ParkrunCourses.startOf(home)!;
    ParkrunCourseStart known(String id, {double northM = 0}) =>
        ParkrunCourseStart(
          courseId: id,
          lat: start.lat + northM / 111195,
          lon: start.lon,
        );

    test('joins a course whose start is within 150 m, the nearest wins', () {
      expect(ParkrunCourses.assign(home, [known('c-a', northM: 140)]), 'c-a');
      expect(
        ParkrunCourses.assign(home, [
          known('c-far', northM: 120),
          known('c-near', northM: 40),
        ]),
        'c-near',
      );
    });

    test('beyond 150 m: a new course with a stable id', () {
      final id = ParkrunCourses.assign(home, [known('c-a', northM: 160)]);
      expect(id, isNot('c-a'));
      expect(id, ParkrunCourses.newCourseId(home));
      expect(id, matches(RegExp(r'^c-[0-9a-f]{8}$')));
      expect(ParkrunCourses.assign(home, const []), id);
    });

    test('an indoor run has no course', () {
      final indoor = home.copyWith(
        samples: [
          for (final s in home.samples) s.copyWith(lat: null, lon: null),
        ],
      );
      expect(ParkrunCourses.assign(indoor, [known('c-a')]), isNull);
    });
  });

  group('parkrun:<courseId> keys', () {
    RunSidecar course(RunFile r, String id) =>
        RunSidecar(runId: r.id).withParkrun(ParkrunInfo(courseId: id));

    test('the course is the key; other courses are never priors', () {
      final a1 = parkrun(n: 1, mps: 3.5);
      final a2 = parkrun(n: 2, mps: 3.6);
      final b1 = parkrun(n: 3, mps: 3.7, latShiftDeg: 0.05);
      final r1 = analyze(a1, sidecar: course(a1, 'c-aaaa0001'));
      expect(r1.comparisonKey, 'parkrun:c-aaaa0001');
      final prior = r1.asPrior(a1.start)!;
      expect(prior.comparisonKey, 'parkrun:c-aaaa0001');
      final r2 = analyze(
        a2,
        sidecar: course(a2, 'c-aaaa0001'),
        priors: [prior],
      );
      expect(r2.verdict!.headline, VerdictHeadline.faster);
      final rb = analyze(
        b1,
        sidecar: course(b1, 'c-bbbb0002'),
        priors: [prior, r2.asPrior(a2.start)!],
      );
      expect(rb.comparisonKey, 'parkrun:c-bbbb0002');
      expect(rb.verdict!.stage, VerdictStage.baseline);
    });

    test('no course yet: plain parkrun key', () {
      expect(analyze(parkrun()).comparisonKey, 'parkrun');
    });

    test('a non-parkrun session ignores a stray course', () {
      final four = fixture('preset_4x4_auto_standard').run;
      final a = engine.analyze(
        four,
        sidecar: RunSidecar(runId: four.id)
            .withParkrun(const ParkrunInfo(courseId: 'c-x')),
        now: fixedNow,
      );
      expect(a.comparisonKey, ComparisonKey.norwegian4x4);
    });
  });

  group('official time (sidecar)', () {
    test('replaces the GPS finish and says so', () {
      final r = parkrun(mps: 3.6); // GPS 23:09
      final gps = analyze(r);
      expect(gps.verdict!.floorSecPerKm, 3);
      final off = analyze(
        r,
        sidecar: RunSidecar(runId: r.id)
            .withParkrun(const ParkrunInfo(officialTimeSeconds: 23 * 60 + 20)),
      );
      expect(off.verdict!.subline, startsWith('Finish 23:20 (official).'));
      expect(off.officialTime, isTrue);
      expect(off.asPrior(r.start)!.officialTime, isTrue);
      expect(off.intervals!.avgRepSeconds, closeTo(1400, 1e-9));
      // The rep keeps its measured GPS numbers.
      expect(
        off.intervals!.reps.single.distanceM,
        gps.intervals!.reps.single.distanceM,
      );
      // It is what the next run is compared with.
      expect(off.asPrior(r.start)!.avgWorkPaceSecPerKm, closeTo(280, 1e-9));
    });

    RunSidecar official(RunFile r, int seconds) =>
        RunSidecar(runId: r.id)
            .withParkrun(ParkrunInfo(officialTimeSeconds: seconds));

    test('1 s/km floor only when both sides are official', () {
      final r1 = parkrun(n: 1, mps: 3.6); // GPS ~23:09
      final r2 = parkrun(n: 2, mps: 3.6);
      final p1gps = analyze(r1).asPrior(r1.start)!;
      final p1off = analyze(r1, sidecar: official(r1, 1390)).asPrior(r1.start)!;
      expect(p1gps.officialTime, isFalse);
      // Official now vs GPS last week: the GPS floor (3 s/km).
      final mixed = analyze(r2, sidecar: official(r2, 1385), priors: [p1gps]);
      expect(mixed.verdict!.stage, VerdictStage.vsLast);
      expect(mixed.verdict!.floorSecPerKm, closeTo(3 * 1.41421356, 1e-6));
      // GPS now vs official last week: GPS floor too.
      final gpsNow = analyze(r2, priors: [p1off]);
      expect(gpsNow.verdict!.floorSecPerKm, closeTo(3 * 1.41421356, 1e-6));
      // Both official: 1 s/km.
      final both = analyze(r2, sidecar: official(r2, 1385), priors: [p1off]);
      expect(both.verdict!.floorSecPerKm, closeTo(1 * 1.41421356, 1e-6));
      // Round trip through the index keeps the flag.
      expect(PriorRun.fromJson(p1off.toJson()).officialTime, isTrue);
      expect(p1gps.toJson().containsKey('official'), isFalse);
    });

    test('an implausible official time (±20% of GPS) is ignored', () {
      final r = parkrun(mps: 3.6); // GPS ~1389 s
      final typo = analyze(r, sidecar: official(r, 2 * 60 + 43));
      expect(typo.officialTime, isFalse);
      expect(typo.verdict!.subline, isNot(contains('(official)')));
      expect(typo.intervals!.avgRepSeconds, closeTo(1389, 3));
      expect(ParkrunInfo.plausibleOfficial(1389 * 12 ~/ 10, 1389), isTrue);
      expect(ParkrunInfo.plausibleOfficial(1389 * 13 ~/ 10, 1389), isFalse);
      expect(ParkrunInfo.plausibleOfficial(1389 * 8 ~/ 10 + 1, 1389), isTrue);
      expect(ParkrunInfo.plausibleOfficial(1389 * 7 ~/ 10, 1389), isFalse);
      // Absolute bounds for a 5 km, with the entry screen's message.
      expect(ParkrunInfo.officialTimeProblem(12 * 60), isNull);
      expect(ParkrunInfo.officialTimeProblem(90 * 60), isNull);
      expect(
        ParkrunInfo.officialTimeProblem(11 * 60 + 59),
        'That time looks off. Enter it as mm:ss, between 12:00 and 1:30:00.',
      );
      expect(ParkrunInfo.officialTimeProblem(90 * 60 + 1), isNotNull);
      expect(
        ParkrunInfo.officialTimeProblem(1700, gpsSeconds: 1389),
        "That's a long way from your GPS time. Check it and try again.",
      );
      // A slow walker's GPS 1:20:00 with an official 1:31:00: out of range.
      expect(ParkrunInfo.plausibleOfficial(91 * 60, 80 * 60), isFalse);
    });

    test('entering it unfreezes the verdict; history keeps the old one', () {
      final r = parkrun();
      final a = analyze(r);
      final frozen = RunSidecar(runId: r.id).withFrozenVerdict(a.verdict!);
      final entered = frozen.withParkrun(
        const ParkrunInfo(officialTimeSeconds: 1400),
      );
      expect(entered.frozenVerdict, isNull);
      expect(entered.verdictHistory.single.subline, a.verdict!.subline);
      expect(entered.inputsKey, isNot(frozen.inputsKey));
      final again = analyze(r, sidecar: entered);
      expect(again.verdictSource, VerdictSource.computed);
      expect(again.verdict!.subline, contains('(official)'));
    });

    test('an official time on a non-parkrun session is ignored', () {
      final four = fixture('preset_4x4_auto_standard').run;
      final plain = engine.analyze(four, now: fixedNow);
      final with1 = engine.analyze(
        four,
        sidecar: RunSidecar(runId: four.id)
            .withParkrun(const ParkrunInfo(officialTimeSeconds: 100)),
        now: fixedNow,
      );
      expect(
        with1.intervals!.avgWorkPaceSecPerKm,
        plain.intervals!.avgWorkPaceSecPerKm,
      );
      expect(with1.verdict!.subline, plain.verdict!.subline);
    });
  });

  group('sidecar', () {
    test('parkrun object round trips; absent stays absent', () {
      final s = RunSidecar(
        runId: '00000000-0000-4000-8000-000000000001',
        parkrun: const ParkrunInfo(
          courseId: 'c-12345678',
          officialTimeSeconds: 1400,
        ),
      );
      final back = RunSidecarCodec.decode(RunSidecarCodec.encode(s));
      expect(back.parkrun, s.parkrun);
      expect((jsonDecode(RunSidecarCodec.encode(s)) as Map)['parkrun'], {
        'course_id': 'c-12345678',
        'official_time_s': 1400,
      });
      final none = RunSidecar(runId: s.runId);
      expect(
        (jsonDecode(RunSidecarCodec.encode(none)) as Map).containsKey(
          'parkrun',
        ),
        isFalse,
      );
      expect(
        RunSidecarCodec.decode(RunSidecarCodec.encode(none)).parkrun,
        null,
      );
    });

    test('bad values are refused', () {
      Map<String, Object?> j(Object? official) => {
        'schema': 3,
        'run_id': '00000000-0000-4000-8000-000000000001',
        'parkrun': {'official_time_s': official},
      };
      expect(
        () => RunSidecar.fromJson(j(-5)),
        throwsA(isA<RunFileFormatException>()),
      );
      expect(
        () => RunSidecar.fromJson(j('23:20')),
        throwsA(isA<RunFileFormatException>()),
      );
    });

    test('earlier inputs keys are byte-for-byte unchanged', () {
      const edits = <LapEdit>[];
      expect(
        RunSidecar(runId: 'x').inputsKey,
        jsonEncode({'edits': edits, 'override': null}),
      );
    });
  });

  group('event names (flavour)', () {
    List<String> copy(EventNames names) {
      final r1 = parkrun(n: 1, mps: 3.5);
      final r2 = parkrun(n: 2, mps: 3.6);
      final r3 = parkrun(n: 3, mps: 3.4);
      final out = <String>[];
      final priors = <PriorRun>[];
      for (final r in [r1, r2, r3]) {
        final a = analyze(r, priors: List.of(priors), names: names);
        out
          ..add(a.verdict!.headline.text)
          ..add(a.verdict!.subline)
          ..add(a.verdict!.hrLine ?? '');
        priors.add(a.asPrior(r.start)!);
      }
      return out;
    }

    test('dogfood says its name', () {
      expect(copy(dogfood).join(' '), contains('parkrun'));
    });

    test('play never says "parkrun" in any verdict string', () {
      final text = copy(play);
      for (final s in text) {
        expect(s.toLowerCase(), isNot(contains('parkrun')), reason: s);
      }
      expect(text.join(' '), contains('5K time trial'));
    });

    test('the generic default is not the trademark', () {
      expect(EventNames.generic.parkrun.toLowerCase(), isNot('parkrun'));
      expect(EventNames.generic.parkrunPlural, '5K time trials');
      expect(
        const EventNames(parkrun: 'x', parkrunPluralName: 'xes').parkrunPlural,
        'xes',
      );
    });

    test('SessionSpec.parkrun takes the injected name', () {
      final s = SessionSpec.parkrun(play.parkrun);
      expect(s.name, '5K time trial');
      expect(s.comparisonKey, ComparisonKey.parkrun);
      expect(s.autoStop, isTrue);
      expect(s.steps.single.value, 5000);
    });
  });
}
