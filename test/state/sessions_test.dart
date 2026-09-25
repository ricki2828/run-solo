import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:run_engine/run_engine.dart' as engine;
import 'package:run_solo/platform/gateway.dart';
import 'package:run_solo/state/sessions.dart';
import 'package:run_solo/state/settings.dart';

void main() {
  group('CustomSession', () {
    test('expands to N reps with N − 1 recoveries and a custom id', () {
      const c = CustomSession(
        id: 'abc',
        name: 'x',
        reps: 6,
        workTarget: engine.TargetKind.distance,
        workValue: 800,
        recoveryValue: 120,
      );
      final s = c.expand();
      expect(s.templateId, 'custom:abc');
      expect(s.repCount, 6);
      expect(s.steps, hasLength(11));
      expect(s.validate(), isEmpty);
      expect(s.comparisonKey, 'd800x*');
      expect(c.autoName, '6 × 800 m · 2:00 jog');
    });

    test('no recovery means straight into the next rep (0:00)', () {
      const c = CustomSession(
        id: 'a',
        name: 'x',
        reps: 3,
        workValue: 60,
        recoveryTarget: RecoveryTarget.none,
      );
      final rec = c.expand().steps.where((s) => !s.isWork);
      expect(rec.every((s) => s.value == 0), isTrue);
      expect(c.autoName, '3 × 1:00 · no recovery');
    });

    test('short time reps get the short cue profile', () {
      const c = CustomSession(id: 'a', name: 'x', workValue: 30);
      expect(c.expand().cueProfile, engine.CueProfile.short);
    });

    test('a standing recovery by distance is invalid (plan §3.3)', () {
      const c = CustomSession(
        id: 'a',
        name: 'x',
        recoveryTarget: RecoveryTarget.distance,
        recoveryValue: 200,
        recoveryStyle: engine.RecoveryStyle.stand,
      );
      expect(c.validate(), isNotEmpty);
    });

    test('JSON round trip', () {
      final c = CustomSession(
        id: 'a1',
        version: 3,
        name: 'Hills',
        reps: 8,
        workValue: 90,
        recoveryTarget: RecoveryTarget.distance,
        recoveryValue: 200,
        warmupSeconds: 600,
        createdAt: DateTime.utc(2026, 9, 25),
      );
      expect(CustomSession.fromJson(c.toJson()), c);
    });
  });

  group('SessionText', () {
    test('structure lines (A8)', () {
      String of(String id) =>
          SessionText.structure(engine.SessionCatalogue.byId(id)!.defaults);
      expect(of('norwegian-4x4'), '4 × 4:00 · 3:00 jog');
      expect(of('400s'), '8 × 400 m · 200 m jog');
      expect(of('yasso-800s'), '6 × 800 m · same-time jog');
      expect(of('pyramid'), '1-2-3-4-3-2-1 min · same-time jog');
      expect(of('1km-repeats'), '5 × 1 km · 2:00 jog');
      expect(
        SessionText.structure(engine.SessionSpec.fartlek),
        'By feel · you press LAP',
      );
    });

    test('estimate: open warm-up and cool-down count 10 min each', () {
      // 10 + 4 × 4 + 3 × 3 + 10 = 45 min.
      expect(
        SessionText.estimateMinutes(
          engine.SessionCatalogue.norwegian4x4.defaults,
        ),
        45,
      );
    });
  });

  group('SessionChoice', () {
    test(
      'resolves presets with edits, customs, fartlek, and drops unknowns',
      () {
        final s = SessionChoice.resolve(
          '400s',
          edits: {
            '400s': PresetEdit(
              reps: 10,
              recovery: engine.SessionStep.recovery(90, rep: 1),
            ),
          },
        )!;
        expect(s.repCount, 10);
        expect(s.name, '10 × 400 m');
        expect(s.steps[1].target, engine.TargetKind.time);
        expect(SessionChoice.needsGps(s), isTrue);

        expect(
          SessionChoice.resolve('fartlek'),
          same(engine.SessionSpec.fartlek),
        );
        expect(SessionChoice.resolve('custom:gone'), isNull);
        expect(SessionChoice.resolve('nope'), isNull);
      },
    );

    test('an out-of-range stored edit falls back to the defaults', () {
      final s = SessionChoice.resolve(
        '30-30s',
        edits: {'30-30s': const PresetEdit(reps: 99)},
      )!;
      expect(s.repCount, 20);
    });

    test('Save as custom: uniform sessions only', () {
      final four = engine.SessionCatalogue.norwegian4x4.expand(reps: 5);
      final c = SessionChoice.asCustom(four, 'n1')!;
      expect(c.reps, 5);
      expect(c.workValue, 240);
      expect(c.recoveryValue, 180);
      expect(c.expand().comparisonKey, four.comparisonKey);
      expect(
        SessionChoice.asCustom(engine.SessionCatalogue.pyramid.defaults, 'p'),
        isNull,
      );
      expect(SessionChoice.asCustom(engine.SessionSpec.fartlek, 'f'), isNull);
    });
  });

  group('AppSettings sessions', () {
    test('sessionId and preset edits round-trip; fartlek records as Laps', () {
      final s = AppSettings(
        sessionId: '400s',
        presetEdits: {
          '400s': PresetEdit(
            reps: 6,
            recovery: engine.SessionStep.recoveryDistance(300, rep: 1),
          ),
        },
      );
      final back = AppSettings.fromJson(
        jsonDecode(jsonEncode(s.toJson())) as Map<String, Object?>,
      );
      expect(back.sessionId, '400s');
      expect(back.presetEdits['400s'], s.presetEdits['400s']);
      expect(back.session(const []).repCount, 6);
      expect(
        const AppSettings(sessionId: 'fartlek').recordMode,
        RecordMode.laps,
      );
      expect(const AppSettings().recordMode, RecordMode.intervals);
    });

    test('the 4x4 edits stay in reps / recoverySeconds', () {
      const s = AppSettings(reps: 5, recoverySeconds: 150);
      final spec = s.session(const []);
      expect(spec.templateId, 'norwegian-4x4');
      expect(spec.repCount, 5);
      expect(spec.steps[1].value, 150);
    });

    test('a deleted custom template falls back to the 4x4', () {
      const s = AppSettings(sessionId: 'custom:gone');
      expect(s.session(const []).templateId, 'norwegian-4x4');
    });
  });

  group('SessionsController + FileSessionsStore', () {
    late Directory dir;
    setUp(() => dir = Directory.systemTemp.createTempSync('sessions'));
    tearDown(() => dir.deleteSync(recursive: true));

    test(
      'save, edit (version bump), rename, duplicate, delete, reload',
      () async {
        final store = FileSessionsStore(dir);
        var t = DateTime.utc(2026, 9, 25, 8);
        final c = SessionsController(store, now: () => t);
        final a = await c.save(
          const CustomSession(id: 'a', name: 'A', workValue: 120),
        );
        t = t.add(const Duration(minutes: 1));
        await c.save(const CustomSession(id: 'b', name: 'B'));
        expect(c.sessions.map((s) => s.id), ['b', 'a'], reason: 'newest first');

        final edited = await c.save(a.copyWith(workValue: 150));
        expect(edited.version, 2);
        final renamed = await c.save(edited.copyWith(name: 'A2'));
        expect(renamed.version, 2, reason: 'a name is not a session change');

        await c.rename('b', 'Bee');
        final dup = await c.duplicate('b');
        expect(dup!.name, 'Bee (copy)');
        await c.delete('a');

        final again = SessionsController(FileSessionsStore(dir));
        await again.load();
        expect(again.sessions.map((s) => s.name).toSet(), {
          'Bee',
          'Bee (copy)',
        });
        final raw = jsonDecode(
          File('${dir.path}/sessions.json').readAsStringSync(),
        );
        expect((raw as Map)['schema'], 1);
      },
    );

    test('at most 20 templates', () async {
      final c = SessionsController(MemorySessionsStore());
      for (var i = 0; i < SessionRules.maxCustom; i++) {
        await c.save(CustomSession(id: 'c$i', name: 'n'));
      }
      expect(c.full, isTrue);
      expect(
        () => c.save(const CustomSession(id: 'x', name: 'n')),
        throwsStateError,
      );
      expect(await c.duplicate('c0'), isNull);
    });

    test(
      'a damaged file loads as no templates; a bad entry is skipped',
      () async {
        File('${dir.path}/sessions.json').writeAsStringSync('{not json');
        expect(await FileSessionsStore(dir).load(), isEmpty);
        File('${dir.path}/sessions.json').writeAsStringSync(
          jsonEncode({
            'schema': 1,
            'sessions': [
              {'id': 'ok', 'name': 'ok', 'reps': 4, 'workValue': 60},
              {'id': 'bad'},
              {'id': 'invalid', 'name': 'x', 'reps': 0, 'workValue': 60},
            ],
          }),
        );
        final loaded = await FileSessionsStore(dir).load();
        expect(loaded.map((s) => s.id), ['ok']);
      },
    );
  });
}
