import 'dart:convert';

import 'package:run_engine/run_engine.dart';
import 'package:test/test.dart';

import 'helpers.dart';

/// Phase 3 plan §3.3 / §3.7 / §3.8: SessionSpec, schema 3 read-time
/// migration, comparison keys, the preset catalogue and per-key floors.
void main() {
  final preset4x4 = fixture('preset_4x4_auto_standard').run;
  final threeRep = fixture('preset_3x4_recovery_2_00').run;
  final byFeel = fixture('four_by_four_manual_clean_hr').run;
  final lapsRun = fixture('laps_run_manual_clean_hr').run;

  group('schema ≤ 2 → 3 mapping', () {
    test('fourByFour + preset → intervals + the norwegian-4x4 session', () {
      final run = RunFileCodec.decode(legacyRunText(preset4x4, 2));
      expect(run.readSchema, 2);
      expect(run.mode, RunMode.intervals);
      final s = run.session!;
      expect(s.templateId, 'norwegian-4x4');
      expect(s.templateVersion, 1);
      expect(s.name, 'Norwegian 4x4');
      expect(s.warmupSeconds, isNull);
      expect(s.cooldownSeconds, isNull);
      expect(s.lapLockout, isFalse);
      expect(s.cueProfile, CueProfile.standard);
      expect((s.hrBandLow, s.hrBandHigh), (0.85, 0.95));
      expect(s.steps, [
        const SessionStep.work(240, rep: 1),
        const SessionStep.recovery(180, rep: 1),
        const SessionStep.work(240, rep: 2),
        const SessionStep.recovery(180, rep: 2),
        const SessionStep.work(240, rep: 3),
        const SessionStep.recovery(180, rep: 3),
        const SessionStep.work(240, rep: 4),
      ], reason: 'N reps, N−1 recoveries');
      expect(
        run.preset,
        const Preset(reps: 4, workSeconds: 240, recoverySeconds: 180),
      );
      // Re-encoded as schema 3: `session`, never `preset` or `fourByFour`.
      final j = jsonDecode(RunFileCodec.encode(run)) as Map<String, Object?>;
      expect(j['schema'], 3);
      expect(j['mode'], 'intervals');
      expect(j.containsKey('preset'), isFalse);
      expect((j['session'] as Map)['templateId'], 'norwegian-4x4');
      expect(
        RunFileCodec.encode(RunFileCodec.decode(jsonEncode(j))),
        RunFileCodec.encode(run),
      );
    });

    test('a 3-rep 4x4 maps to 3 work steps and 2 recoveries (W1)', () {
      final run = RunFileCodec.decode(legacyRunText(threeRep, 2));
      expect(run.session!.repCount, 3);
      expect(run.session!.steps.length, 5);
      expect(run.session!.comparisonKey, 't240x*');
      expect(
        run.preset,
        const Preset(reps: 3, workSeconds: 240, recoverySeconds: 120),
      );
    });

    test('a by-feel 4x4 (no preset) stays by-feel, judged as a 4x4', () {
      final run = RunFileCodec.decode(legacyRunText(byFeel, 2));
      expect(run.mode, RunMode.intervals);
      expect(run.session, isNull);
      expect(run.preset, isNull, reason: 'the detector stays by-feel');
      final a = engine.analyze(run, now: fixedNow);
      expect(a.session!.templateId, 'norwegian-4x4');
      expect(a.comparisonKey, 't240x*');
    });

    test('schema-1 by-feel run with override fourByFour → intervals + the '
        'norwegian-4x4 spec (eng-review test-plan gap)', () {
      final run = RunFileCodec.decode(legacyRunText(lapsRun, 1));
      expect(run.readSchema, 1);
      expect(run.mode, RunMode.laps);
      final sidecar = RunSidecarCodec.decode(
        jsonEncode(
          legacySidecarJson(
            RunSidecar(runId: run.id, runTypeOverride: RunMode.intervals),
            1,
          ),
        ),
      );
      expect(sidecar.readSchema, 1);
      expect(sidecar.runTypeOverride, RunMode.intervals);
      final a = engine.analyze(run, sidecar: sidecar, now: fixedNow);
      expect(a.mode, RunMode.intervals);
      expect(a.session, SessionSpec.norwegian4x4());
      expect(a.comparisonKey, 't240x*');
      expect(a.verdict, isNotNull);
      // Same for a schema-2 sidecar spelling it `fourByFour`.
      final v2 = RunSidecarCodec.decode(
        jsonEncode(
          legacySidecarJson(
            RunSidecar(runId: run.id, runTypeOverride: RunMode.intervals),
            2,
          ),
        ),
      );
      expect(v2.runTypeOverride, RunMode.intervals);
    });

    test('schema-2 cooper → the Cooper session', () {
      final j = legacyRunJson(lapsRun, 2)..['mode'] = 'cooper';
      final run = RunFile.fromJson(j);
      expect(run.mode, RunMode.cooper);
      expect(run.session, SessionSpec.cooper);
      expect(run.session!.lapLockout, isTrue);
      expect(engine.analyze(run, now: fixedNow).comparisonKey, 'cooper');
    });

    test('schema 3 refuses the retired spellings and mismatched sessions', () {
      final good = preset4x4.toJson();
      expect(
        () => RunFile.fromJson(Map.of(good)..['mode'] = 'fourByFour'),
        throwsA(isA<RunFileFormatException>()),
      );
      expect(
        () => RunFile.fromJson(Map.of(good)..['preset'] = null),
        throwsA(isA<RunFileNewerVersionException>()),
        reason: 'an unknown key in schema 3',
      );
      expect(
        () => RunFile.fromJson(Map.of(good)..['mode'] = 'free'),
        throwsA(isA<RunFileFormatException>()),
        reason: 'a free run carries no session',
      );
      expect(
        () => RunFile.fromJson(
          Map.of(good)
            ..['mode'] = 'cooper'
            ..['session'] = null,
        ),
        throwsA(isA<RunFileFormatException>()),
      );
      final fartlek = lapsRun.copyWith(session: SessionSpec.fartlek);
      expect(
        RunFileCodec.decode(RunFileCodec.encode(fartlek)).session,
        SessionSpec.fartlek,
      );
      expect(engine.analyze(fartlek, now: fixedNow).comparisonKey, 'fartlek');
      expect(engine.analyze(lapsRun, now: fixedNow).comparisonKey, isNull);
    });

    test('schema-2 sidecar override maps; comparison_key is a cache', () {
      final s = RunSidecar(
        runId: preset4x4.id,
        runTypeOverride: RunMode.intervals,
      ).copyWith(comparisonKey: 't240x*');
      final back = RunSidecarCodec.decode(RunSidecarCodec.encode(s));
      expect(back.comparisonKey, 't240x*');
      expect(back.runTypeOverride, RunMode.intervals);
      final j = jsonDecode(RunSidecarCodec.encode(s)) as Map;
      expect(j['run_type_override'], 'intervals');
      expect(
        () => RunSidecar.fromJson(
          (jsonDecode(RunSidecarCodec.encode(s)) as Map<String, Object?>)
            ..['run_type_override'] = 'fourByFour',
        ),
        throwsA(isA<RunFileFormatException>()),
        reason: 'schema 3 does not spell fourByFour',
      );
    });
  });

  group('SessionSpec validation (plan §3.3 table)', () {
    SessionSpec spec(List<SessionStep> steps, {int? warmup}) => SessionSpec(
      templateId: 'custom:x',
      templateVersion: 1,
      name: 'x',
      warmupSeconds: warmup,
      steps: steps,
    );

    test('every catalogue default and the fixed specs are valid', () {
      for (final p in SessionCatalogue.presets) {
        expect(p.defaults.validate(), isEmpty, reason: p.id);
      }
      expect(SessionSpec.cooper.validate(), isEmpty);
      expect(SessionSpec.fartlek.validate(), isEmpty);
      expect(
        SessionSpec.norwegian4x4(reps: 6, recoverySeconds: 300).validate(),
        isEmpty,
      );
    });

    test('rules', () {
      expect(spec([const SessionStep.work(240, rep: 1)]).validate(), isEmpty);
      // 0 s recovery = straight into the next rep.
      expect(
        spec([
          const SessionStep.work(60, rep: 1),
          const SessionStep.recovery(0, rep: 1),
          const SessionStep.work(60, rep: 2),
        ]).validate(),
        isEmpty,
      );
      final bad = {
        'no steps': spec([]),
        'ends in recovery': spec([
          const SessionStep.work(60, rep: 1),
          const SessionStep.recovery(60, rep: 1),
        ]),
        'work 14 s': spec([const SessionStep.work(14, rep: 1)]),
        'work 1201 s': spec([const SessionStep.work(1201, rep: 1)]),
        'distance 99 m': spec([const SessionStep.workDistance(99, rep: 1)]),
        'distance 10001 m': spec([
          const SessionStep.workDistance(10001, rep: 1),
        ]),
        'recovery 601 s': spec([
          const SessionStep.work(60, rep: 1),
          const SessionStep.recovery(601, rep: 1),
          const SessionStep.work(60, rep: 2),
        ]),
        'stand by distance': spec([
          const SessionStep.work(60, rep: 1),
          const SessionStep.recoveryDistance(
            200,
            rep: 1,
            style: RecoveryStyle.stand,
          ),
          const SessionStep.work(60, rep: 2),
        ]),
        'walk by distance': spec([
          const SessionStep.work(60, rep: 1),
          const SessionStep.recoveryDistance(
            200,
            rep: 1,
            style: RecoveryStyle.walk,
          ),
          const SessionStep.work(60, rep: 2),
        ]),
        'two works in a row': spec([
          const SessionStep.work(60, rep: 1),
          const SessionStep.work(60, rep: 2),
        ]),
        'wrong rep number': spec([
          const SessionStep.work(60, rep: 1),
          const SessionStep.recovery(60, rep: 2),
          const SessionStep.work(60, rep: 2),
        ]),
        '41 reps': spec(
          SessionSpec.uniform(
            reps: 41,
            work: (r) => SessionStep.work(30, rep: r),
            recovery: (r) => SessionStep.recovery(30, rep: r),
          ),
        ),
        'warm-up 299 s': spec([
          const SessionStep.work(60, rep: 1),
        ], warmup: 299),
        'equal-time work': spec([
          const SessionStep(
            kind: StepKind.work,
            target: TargetKind.equalToPreviousWork,
            value: 0,
            style: RecoveryStyle.run,
            rep: 1,
          ),
        ]),
      };
      for (final e in bad.entries) {
        expect(e.value.validate(), isNotEmpty, reason: e.key);
      }
      expect(
        spec(
          SessionSpec.uniform(
            reps: 40,
            work: (r) => SessionStep.work(30, rep: r),
            recovery: (r) => SessionStep.recovery(30, rep: r),
          ),
        ).validate(),
        isEmpty,
        reason: '40 reps = 79 steps, inside the 80 cap',
      );
    });

    test('fromJson refuses an invalid spec and an unknown key', () {
      final j = SessionSpec.norwegian4x4().toJson();
      expect(SessionSpec.fromJson(j), SessionSpec.norwegian4x4());
      expect(
        () => SessionSpec.fromJson(Map.of(j)..['pace'] = 250),
        throwsA(isA<RunFileNewerVersionException>()),
      );
      expect(
        () => SessionSpec.fromJson(Map.of(j)..['steps'] = <Object?>[]),
        throwsA(isA<RunFileFormatException>()),
      );
      expect(
        () => SessionSpec.fromJson(Map.of(j)..['cueProfile'] = 'loud'),
        throwsA(isA<RunFileFormatException>()),
      );
    });

    test('wire shape is flat and in canonical key order', () {
      final j = SessionCatalogue.fourHundreds.defaults.toJson();
      expect(j.keys.toList(), [
        'templateId',
        'templateVersion',
        'name',
        'warmupSeconds',
        'cooldownSeconds',
        'lapLockout',
        'cueProfile',
        'hrBand',
        'steps',
      ]);
      expect((j['steps'] as List).first, {
        'kind': 'work',
        'target': 'distance',
        'value': 400,
        'style': 'run',
        'rep': 1,
      });
      expect((j['steps'] as List)[1], {
        'kind': 'recovery',
        'target': 'distance',
        'value': 200,
        'style': 'jog',
        'rep': 1,
      });
    });
  });

  group('comparison key (plan §3.3, D4)', () {
    test('work steps only: rep count and recovery do not change it', () {
      expect(SessionSpec.norwegian4x4(reps: 3).comparisonKey, 't240x*');
      expect(
        SessionSpec.norwegian4x4(reps: 6, recoverySeconds: 300).comparisonKey,
        't240x*',
      );
      expect(SessionCatalogue.thirtyThirty.defaults.comparisonKey, 't30x*');
      expect(SessionCatalogue.oneMinute.defaults.comparisonKey, 't60x*');
      expect(SessionCatalogue.tempo.defaults.comparisonKey, 't480x*');
      expect(
        SessionCatalogue.tempo.expand(workValue: 600).comparisonKey,
        't600x*',
        reason: 'a different rep length is a different session',
      );
      expect(SessionCatalogue.fourHundreds.defaults.comparisonKey, 'd400x*');
      expect(
        SessionCatalogue.fourHundreds
            .expand(reps: 12, recovery: const SessionStep.recovery(90, rep: 1))
            .comparisonKey,
        'd400x*',
      );
      expect(SessionCatalogue.yasso.defaults.comparisonKey, 'd800x*');
      expect(SessionCatalogue.kmRepeats.defaults.comparisonKey, 'd1000x*');
      expect(
        SessionCatalogue.pyramid.defaults.comparisonKey,
        'pyr:60,120,180,240,180,120,60',
      );
      expect(SessionSpec.cooper.comparisonKey, 'cooper');
      expect(SessionSpec.fartlek.comparisonKey, 'fartlek');
      expect(
        const SessionSpec(
          templateId: 'custom:a',
          templateVersion: 1,
          name: 'mix',
          steps: [
            SessionStep.work(60, rep: 1),
            SessionStep.recovery(60, rep: 1),
            SessionStep.workDistance(400, rep: 2),
          ],
        ).comparisonKey,
        'mix:t60,d400',
      );
      expect(
        const SessionSpec(
          templateId: 'custom:b',
          templateVersion: 1,
          name: 'ladder',
          steps: [
            SessionStep.workDistance(400, rep: 1),
            SessionStep.recoveryEqualTime(rep: 1),
            SessionStep.workDistance(800, rep: 2),
          ],
        ).comparisonKey,
        'dpyr:400,800',
      );
    });

    test('a custom 5 × 4:00 / 2:30 shares the 4x4 history', () {
      final custom = SessionSpec(
        templateId: 'custom:9b1f',
        templateVersion: 3,
        name: '5 × 4:00 · 2:30 jog',
        steps: SessionSpec.uniform(
          reps: 5,
          work: (r) => SessionStep.work(240, rep: r),
          recovery: (r) => SessionStep.recovery(150, rep: r),
        ),
      );
      expect(custom.validate(), isEmpty);
      expect(custom.comparisonKey, SessionSpec.norwegian4x4().comparisonKey);
    });
  });

  group('catalogue (plan §3.1, D1, D2)', () {
    test('the eight presets in picker order', () {
      expect(SessionCatalogue.presets.map((p) => p.name).toList(), [
        'Norwegian 4x4',
        '30/30s',
        '1-minute reps',
        'Pyramid',
        'Tempo intervals',
        '8 × 400 m',
        'Yasso 800s',
        '1 km repeats',
      ]);
      expect(SessionCatalogue.presets.map((p) => p.id).toSet().length, 8);
    });

    test('defaults match the plan table', () {
      final d = {for (final p in SessionCatalogue.presets) p.id: p.defaults};
      expect(d['norwegian-4x4'], SessionSpec.norwegian4x4());
      expect(d['30-30s']!.repCount, 20);
      expect(d['30-30s']!.cueProfile, CueProfile.short);
      expect(d['1-min-reps']!.repCount, 10);
      expect(
        d['pyramid']!.steps
            .where((s) => !s.isWork)
            .every((s) => s.target == TargetKind.equalToPreviousWork),
        isTrue,
      );
      expect(d['pyramid']!.steps.length, 13);
      expect(d['tempo']!.repCount, 3);
      expect((d['tempo']!.hrBandLow, d['tempo']!.hrBandHigh), (0.80, 0.90));
      expect(d['400s']!.repCount, 8);
      expect(d['yasso-800s']!.repCount, 6);
      expect(d['1km-repeats']!.repCount, 5);
      for (final s in d.values) {
        expect(s.warmupSeconds, isNull, reason: 'open warm-up (plan §3.1)');
        expect(s.cooldownSeconds, isNull);
      }
    });

    test('only the table fields are editable, inside their ranges', () {
      expect(SessionCatalogue.expand('norwegian-4x4', reps: 6).repCount, 6);
      expect(
        () => SessionCatalogue.expand('norwegian-4x4', reps: 7),
        throwsArgumentError,
      );
      expect(
        () => SessionCatalogue.expand('norwegian-4x4', workValue: 300),
        throwsArgumentError,
        reason: 'work length is "Save as custom"',
      );
      expect(
        () => SessionCatalogue.expand(
          'norwegian-4x4',
          recovery: const SessionStep.recovery(301, rep: 1),
        ),
        throwsArgumentError,
      );
      expect(
        () => SessionCatalogue.expand('pyramid', reps: 5),
        throwsArgumentError,
      );
      expect(
        () => SessionCatalogue.expand(
          '30-30s',
          recovery: const SessionStep.recovery(45, rep: 1),
        ),
        throwsArgumentError,
      );
      final timed400 = SessionCatalogue.expand(
        '400s',
        reps: 10,
        recovery: const SessionStep.recovery(90, rep: 1),
      );
      expect(timed400.name, '10 × 400 m');
      expect(timed400.steps[1], const SessionStep.recovery(90, rep: 1));
      expect(timed400.validate(), isEmpty);
      expect(
        () => SessionCatalogue.expand(
          '400s',
          recovery: const SessionStep.recoveryDistance(450, rep: 1),
        ),
        throwsArgumentError,
      );
      expect(() => SessionCatalogue.expand('nope'), throwsArgumentError);
    });
  });

  group('noise floor per key (plan §3.7, W1)', () {
    const c = EngineConstants.defaults;

    test('the 4x4 key is a constant 10 s/km whatever the rep count', () {
      expect(c.floorSecPerKmForKey('t240x*'), 10);
      expect(
        c.floorSecPerKmForKey(
          't240x*',
          templateDefault: SessionSpec.norwegian4x4(reps: 3),
        ),
        10,
      );
    });

    test('other keys: 10 × sqrt(16 min ÷ nominal work min), 10..20', () {
      // 30/30s: 20 × 30 s = 10 min → 12.65.
      expect(c.floorSecPerKmForKey('t30x*'), closeTo(12.65, 0.01));
      // 1-minute reps: 10 min → 12.65.
      expect(c.floorSecPerKmForKey('t60x*'), closeTo(12.65, 0.01));
      // Tempo 3 × 8:00 = 24 min → 8.2, clamped to 10.
      expect(c.floorSecPerKmForKey('t480x*'), 10);
      // 8 × 400 m at the nominal 5:00/km = 16 min → 10.
      expect(c.floorSecPerKmForKey('d400x*'), 10);
      // A custom 6 × 0:20 (2 min) → sqrt(8) × 10 = 28.3, clamped to 20.
      final custom = SessionSpec(
        templateId: 'custom:c',
        templateVersion: 1,
        name: '6 × 0:20',
        steps: SessionSpec.uniform(
          reps: 6,
          work: (r) => SessionStep.work(20, rep: r),
          recovery: (r) => SessionStep.recovery(40, rep: r),
        ),
      );
      expect(c.floorSecPerKmForKey('t20x*', templateDefault: custom), 20);
      // No preset owns the key and no template given: the base floor.
      expect(c.floorSecPerKmForKey('t20x*'), 10);
    });

    test('distance keys state the floor per rep', () {
      expect(EngineConstants.floorSecPerRep(12, 400), closeTo(4.8, 1e-9));
    });
  });

  group('plumbing', () {
    test('priors of another key are ignored', () {
      final other = PriorRun(
        id: 'x',
        start: fixedNow.subtract(const Duration(days: 3)),
        avgWorkPaceSecPerKm: 200,
        comparisonKey: 'd400x*',
      );
      final a = engine.analyze(preset4x4, priors: [other], now: fixedNow);
      expect(a.verdict!.stage, VerdictStage.baseline);
      final same = engine.analyze(
        preset4x4,
        priors: [
          PriorRun(
            id: 'x',
            start: fixedNow.subtract(const Duration(days: 3)),
            avgWorkPaceSecPerKm: 200,
          ),
        ],
        now: fixedNow,
      );
      expect(same.verdict!.stage, VerdictStage.vsLast);
      expect(same.asPrior(fixedNow)?.comparisonKey, 't240x*');
    });

    test('a session the Phase 2 detector cannot judge gets no verdict yet '
        '(I3), only its lap table and key', () {
      final run = lapsRun.copyWith(
        mode: RunMode.intervals,
        session: SessionCatalogue.fourHundreds.defaults,
      );
      expect(run.preset, isNull);
      final a = engine.analyze(run, now: fixedNow);
      expect(a.verdict, isNull);
      expect(a.laps, isNotNull);
      expect(a.comparisonKey, 'd400x*');
      expect(a.session!.templateId, '400s');
    });

    test('legacy preset view', () {
      expect(
        SessionSpec.norwegian4x4(reps: 5, recoverySeconds: 150).legacyPreset,
        const Preset(reps: 5, workSeconds: 240, recoverySeconds: 150),
      );
      expect(SessionCatalogue.pyramid.defaults.legacyPreset, isNull);
      expect(SessionCatalogue.yasso.defaults.legacyPreset, isNull);
    });
  });
}
