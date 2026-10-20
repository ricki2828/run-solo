import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:run_engine/run_engine.dart' as engine;
import 'package:run_solo/platform/gateway.dart';
import 'package:run_solo/state/settings.dart';
import 'package:run_solo/state/start_briefing.dart';
import 'package:run_solo/state/voice_coach_plan.dart';

engine.BlockSession _session(
  engine.BlockKind kind, {
  String? presetId,
  int? minutes,
  int? reps,
  double? minDistanceM,
}) => engine.BlockSession(
  id: 'w1s1',
  week: 1,
  dayOffset: 0,
  role: engine.BlockRole.values.first,
  kind: kind,
  reason: 'test',
  presetId: presetId,
  minutes: minutes,
  reps: reps,
  minDistanceM: minDistanceM,
);

/// Worst-case spoken length of each slot, in words, as the server's `briefing.py` SLOT_WORDS counts them (the
/// recorder counts the rendered text for real and falls back; this proves the app's own lines fit). The session
/// slot is the plan's own spoken name, counted as it is.
const _slotWords = {'pace': 6, 'minutes': 4, 'distance': 5, 'reps': 2};

int _renderedWords(String template, {String? session}) => template
    .replaceAllMapped(
      RegExp(r'\{(\w+)\}'),
      (m) => m[1] == 'session'
          ? session!
          : List.filled(_slotWords[m[1]]!, 'w').join(' '),
    )
    .split(RegExp(r'\s+'))
    .where((w) => w.isNotEmpty)
    .length;

Set<String> _slotsOf(String template) => {
  for (final m in RegExp(r'\{(\w+)\}').allMatches(template)) m[1]!,
};

void main() {
  group('fingerprint matches the server', () {
    // The fixture is a copy of companion-server/tests/fixtures/briefing_fingerprint.json on branch
    // c2b-briefing-server (PR #350), whose briefing.py FINGERPRINT section is the spec. If the server pins the
    // rounding differently, copy the new fixture over this one; do not edit the cases here.
    final fixture = jsonDecode(
      File('test/fixtures/briefing_fingerprint.json').readAsStringSync(),
    ) as Map<String, Object?>;
    final cases = (fixture['cases']! as List).cast<Map<String, Object?>>();

    test('the fixture is there and has the float cases', () {
      expect(fixture['version'], 'v1');
      expect(cases.length, greaterThanOrEqualTo(9));
    });

    for (final c in cases) {
      test('${c['name']}', () {
        final i = c['input']! as Map<String, Object?>;
        expect(
          StartBriefing.canonical(
            kind: i['kind']! as String,
            minutes: i['minutes'] as num?,
            distanceM: i['distance_m'] as num?,
            reps: i['reps'] as num?,
            paceLo: i['pace_lo'] as num?,
            paceHi: i['pace_hi'] as num?,
          ),
          c['canonical'],
        );
        expect(
          StartBriefing.fingerprint(
            kind: i['kind']! as String,
            minutes: i['minutes'] as num?,
            distanceM: i['distance_m'] as num?,
            reps: i['reps'] as num?,
            paceLo: i['pace_lo'] as num?,
            paceHi: i['pace_hi'] as num?,
          ),
          c['fingerprint'],
        );
      });
    }

    String hashOf(String name) =>
        cases.firstWhere((c) => c['name'] == name)['fingerprint']! as String;

    test(
      'a plan session hashes to the fixture, from the facts the upload sends',
      () {
        final moved = engine.TargetPaces.fromVdot(
          40,
          adopted: {engine.PaceIntensity.vo2max: 288},
        );
        expect(
          StartBriefing.fingerprintOf(
            _session(
              engine.BlockKind.interval,
              presetId: engine.SessionSpec.norwegian4x4Id,
              minutes: 30,
            ),
            paces: moved,
          ),
          hashOf('norwegian 4x4, pace band'),
          reason: 'reps come from the NxM in norwegian_4x4',
        );
        expect(
          StartBriefing.fingerprintOf(
            _session(engine.BlockKind.easy, minutes: 40),
          ),
          hashOf('easy run, minutes only'),
        );
        expect(
          StartBriefing.fingerprintOf(
            _session(engine.BlockKind.long, minDistanceM: 14000),
          ),
          hashOf('long run, distance only'),
        );
        expect(
          StartBriefing.fingerprintOf(_session(engine.BlockKind.easy)),
          hashOf('nothing planned beyond the kind'),
        );
      },
    );

    test('a changed plan is a different fingerprint', () {
      final a = StartBriefing.fingerprintOf(
        _session(engine.BlockKind.easy, minutes: 40),
      );
      expect(
        StartBriefing.fingerprintOf(
          _session(engine.BlockKind.easy, minutes: 45),
        ),
        isNot(a),
      );
      expect(
        StartBriefing.fingerprintOf(
          _session(engine.BlockKind.long, minutes: 40),
        ),
        isNot(a),
        reason: 'kind is part of the hash (a session made easy is easy)',
      );
    });

    test('reps come from an NxM in the id or name, as on the server', () {
      expect(StartBriefing.repsFrom('norwegian_4x4', 'Norwegian 4x4'), 4);
      expect(StartBriefing.repsFrom(null, '6 x 400 m'), 6);
      expect(StartBriefing.repsFrom('tempo', 'Tempo intervals'), isNull);
      expect(StartBriefing.repsFrom(null, null), isNull);
      expect(StartBriefing.repsFrom('30_30s', '30/30s'), isNull);
    });
  });

  group('the app\'s own briefing', () {
    test('a Norwegian 4x4 keeps its intro and names the session first', () {
      final p = StartBriefing.plan(
        _session(
          engine.BlockKind.interval,
          presetId: engine.SessionSpec.norwegian4x4Id,
          minutes: 30,
          reps: 4,
        ),
        hasPace: true,
      )!;
      expect(p.sessionName, 'Norwegian 4 by 4');
      expect(p.reps, 4);
      expect(p.minutes, 30);
      expect(p.fallback, startsWith('{session}.'));
      expect(p.fallback, contains('Warm up as long as you like.'));
      expect(p.fallback, contains('{reps}'));
      expect(p.fallback, contains('{pace}'));
    });

    test('reps are the plan\'s for the week, not the NxM in the name', () {
      for (final n in [3, 4, 5]) {
        final p = StartBriefing.plan(
          _session(
            engine.BlockKind.interval,
            presetId: engine.SessionSpec.norwegian4x4Id,
            reps: n,
          ),
          hasPace: true,
        )!;
        expect(p.reps, n);
        // The fingerprint still reads the name (the server contract).
        expect(
          StartBriefing.fingerprintOf(
            _session(
              engine.BlockKind.interval,
              presetId: engine.SessionSpec.norwegian4x4Id,
              reps: n,
            ),
          ),
          StartBriefing.fingerprint(kind: 'quality', reps: 4),
        );
      }
      expect(
        StartBriefing.plan(
          _session(
            engine.BlockKind.interval,
            presetId: engine.SessionSpec.norwegian4x4Id,
          ),
          hasPace: true,
        )!.reps,
        4,
        reason: 'no plan reps: the catalogue default',
      );
    });

    test('easy and long name the run first and say one pacing line', () {
      final easy = StartBriefing.plan(
        _session(engine.BlockKind.easy, minutes: 40),
        hasPace: true,
      )!;
      expect(easy.fallback, startsWith('Easy run, {minutes}.'));
      expect(easy.sessionName, isNull);
      expect(easy.reps, isNull);
      final long = StartBriefing.plan(
        _session(engine.BlockKind.long, minutes: 90),
        hasPace: true,
      )!;
      expect(long.fallback, startsWith('Long run, {minutes}.'));
      final longTest = StartBriefing.plan(
        _session(engine.BlockKind.long, minDistanceM: 15000),
        hasPace: false,
      )!;
      expect(longTest.fallback, startsWith('Long run, {distance} or more.'));
      expect(longTest.distanceM, 15000);
      expect(
        StartBriefing.plan(
          _session(engine.BlockKind.easy),
          hasPace: false,
        )!.fallback,
        startsWith('Easy run. '),
      );
    });

    test('a goal run, no session and no plan keep their own start line', () {
      expect(
        StartBriefing.plan(_session(engine.BlockKind.goal), hasPace: true),
        isNull,
      );
      expect(StartBriefing.plan(null, hasPace: true), isNull);
    });

    test(
      'only slots the config can fill, never a digit, a dash or over the cap',
      () {
        for (final preset in engine.SessionCatalogue.presets) {
          for (final hasPace in [true, false]) {
            final s = _session(
              engine.BlockKind.interval,
              presetId: preset.id,
              minutes: 40,
              reps: preset.defaultReps,
            );
            final p = StartBriefing.plan(s, hasPace: hasPace)!;
            final slots = _slotsOf(p.fallback);
            expect(
              slots.difference({'session', 'pace', 'reps', 'minutes'}),
              isEmpty,
              reason: preset.id,
            );
            if (p.sessionName == null) {
              expect(slots, isNot(contains('session')));
            }
            if (p.reps == null) {
              expect(slots, isNot(contains('reps')));
            }
            if (!hasPace) {
              expect(slots, isNot(contains('pace')));
            }
            expect(
              _renderedWords(p.fallback, session: p.sessionName),
              lessThanOrEqualTo(StartBriefing.maxWords),
              reason: '${preset.id}: ${p.fallback}',
            );
            expect(p.fallback, isNot(contains('\u2014')));
            expect(p.fallback, isNot(contains('\u2013')));
            expect(p.fallback, isNot(contains(RegExp(r'\d'))));
          }
        }
        for (final kind in [engine.BlockKind.easy, engine.BlockKind.long]) {
          for (final (m, d) in [(40, null), (null, 15000.0), (null, null)]) {
            final p = StartBriefing.plan(
              _session(kind, minutes: m, minDistanceM: d),
              hasPace: true,
            )!;
            expect(
              _renderedWords(p.fallback),
              lessThanOrEqualTo(StartBriefing.maxWords),
              reason: p.fallback,
            );
            expect(p.fallback, isNot(contains(RegExp(r'\d'))));
          }
        }
      },
    );

    test('the exact templates the Kotlin voice_copy.tsv fixture mirrors', () {
      // android/core-jvm/.../VoiceCopyFixture.kt fills these (the briefing.* lines): change one here, change it there.
      String of(
        engine.BlockKind kind, {
        bool norwegian = false,
        bool hasSession = false,
        bool hasMinutes = false,
        bool hasDistance = false,
        bool hasReps = false,
        bool hasPace = false,
      }) => StartBriefing.fallback(
        kind: kind,
        norwegian: norwegian,
        hasSession: hasSession,
        hasMinutes: hasMinutes,
        hasDistance: hasDistance,
        hasReps: hasReps,
        hasPace: hasPace,
      );
      expect(
        of(
          engine.BlockKind.interval,
          norwegian: true,
          hasSession: true,
          hasReps: true,
          hasPace: true,
        ),
        '{session}. Warm up as long as you like. Then {reps}, hard but even, holding {pace}. Jog the recoveries.',
      );
      expect(
        of(
          engine.BlockKind.interval,
          norwegian: true,
          hasSession: true,
          hasReps: true,
        ),
        '{session}. Warm up as long as you like. Then {reps}, hard but even. Jog the recoveries.',
      );
      expect(
        of(
          engine.BlockKind.interval,
          hasSession: true,
          hasReps: true,
          hasPace: true,
        ),
        '{session}. Today is {reps}. Hold {pace} on each one and jog the recoveries.',
      );
      expect(
        of(engine.BlockKind.interval, hasSession: true, hasPace: true),
        '{session}. Hold {pace} on each one and jog the recoveries.',
      );
      expect(
        of(engine.BlockKind.interval, hasSession: true),
        '{session}. Run each one hard but even and jog the recoveries.',
      );
      expect(
        of(engine.BlockKind.easy, hasMinutes: true),
        'Easy run, {minutes}. Keep it relaxed and conversational. If you cannot chat, ease off.',
      );
      expect(
        of(engine.BlockKind.easy),
        'Easy run. Keep it relaxed and conversational. If you cannot chat, ease off.',
      );
      expect(
        of(engine.BlockKind.long, hasMinutes: true),
        'Long run, {minutes}. Start patient and steady, and save something for the last third.',
      );
      expect(
        of(engine.BlockKind.long, hasDistance: true),
        'Long run, {distance} or more. Start patient and steady, and save something for the last third.',
      );
      expect(
        of(engine.BlockKind.long),
        'Long run. Start patient and steady, and save something for the last third.',
      );
    });

    test('session names are readable aloud', () {
      expect(StartBriefing.spoken('Norwegian 4x4'), 'Norwegian 4 by 4');
      expect(StartBriefing.spoken('6 × 400 m'), '6 by 400 metres');
      expect(StartBriefing.spoken('30/30s'), '30 30s');
      expect(StartBriefing.spoken('1 km repeats'), '1 kilometre repeats');
      expect(StartBriefing.spoken('1-minute reps'), '1 minute reps');
      expect(StartBriefing.spoken('---'), isNull);
      final long = StartBriefing.spoken(
        'Mount Wellington summit via the old pipe track',
      )!;
      expect(long.length, lessThanOrEqualTo(40));
      expect(long, 'Mount Wellington summit via the old');
    });
  });

  group('VoiceCoachPlan.build carries the briefing', () {
    final zones = engine.HrZones.percentMax(190);
    const vdot = 45.0;
    final norwegian = _session(
      engine.BlockKind.interval,
      presetId: engine.SessionSpec.norwegian4x4Id,
      minutes: 30,
      reps: 4,
    );

    test(
      'build is synchronous: the Start path reads nothing over the network',
      () {
        final Object c = VoiceCoachPlan.build(
          settings: const AppSettings(),
          zones: zones,
          planned: norwegian,
          vdot: vdot,
        );
        expect(c, isA<VoiceCoachConfig>());
        expect(c, isNot(isA<Future<Object?>>()));
      },
    );

    test('a plan session carries the app\'s template and its slot values', () {
      final c = VoiceCoachPlan.build(
        settings: const AppSettings(),
        zones: zones,
        planned: norwegian,
        vdot: vdot,
      );
      expect(c.briefingTemplate, isNull, reason: 'the coach has none yet');
      expect(c.briefingFallback, contains('Warm up as long as you like.'));
      expect(c.sessionName, 'Norwegian 4 by 4');
      expect(c.reps, 4);
      expect(c.plannedMinutes, 30, reason: 'for {minutes}');
      expect(
        c.plannedKind,
        isNull,
        reason: 'no planned-time cues on intervals',
      );
      expect(c.targetPaceSecPerKm, isNotNull, reason: 'for {pace}');
    });

    test('the coach\'s template rides along, matched by the caller', () {
      final c = VoiceCoachPlan.build(
        settings: const AppSettings(),
        zones: zones,
        planned: norwegian,
        vdot: vdot,
        briefingTemplate: 'Four by four today. Hold {pace}.',
      );
      expect(c.briefingTemplate, 'Four by four today. Hold {pace}.');
      expect(
        c.briefingFallback,
        isNotNull,
        reason: 'the app\'s own is the fallback',
      );
    });

    test('an easy and a long plan run carry their line and distance', () {
      final easy = VoiceCoachPlan.build(
        settings: const AppSettings(),
        zones: zones,
        planned: _session(engine.BlockKind.easy, minutes: 40),
        vdot: vdot,
      );
      expect(easy.briefingFallback, startsWith('Easy run, {minutes}.'));
      expect(easy.plannedKind, 'easy');
      expect(easy.plannedMinutes, 40);
      expect(easy.sessionName, isNull);
      final long = VoiceCoachPlan.build(
        settings: const AppSettings(),
        zones: zones,
        planned: _session(engine.BlockKind.long, minDistanceM: 15000),
        vdot: vdot,
      );
      expect(
        long.briefingFallback,
        startsWith('Long run, {distance} or more.'),
      );
      expect(long.plannedDistanceM, 15000);
    });

    test(
      'free, warned easy, goal, trail, Minimal and off carry no briefing',
      () {
        final cases = <VoiceCoachConfig>[
          VoiceCoachPlan.build(settings: const AppSettings(), zones: zones),
          VoiceCoachPlan.build(
            settings: const AppSettings(),
            zones: zones,
            warnedEasy: true,
          ),
          VoiceCoachPlan.build(
            settings: const AppSettings(),
            zones: zones,
            planned: _session(engine.BlockKind.goal, minutes: 30),
            goalPaceSecPerKm: 295,
            // Even handed a template, a goal run does not use it.
            briefingTemplate: 'A goal briefing.',
          ),
          VoiceCoachPlan.build(
            settings: const AppSettings(),
            zones: zones,
            sessionPaceSecPerKm: 300,
            briefingTemplate: 'A trail briefing.',
          ),
          VoiceCoachPlan.build(
            settings: const AppSettings(coachingDetail: CoachingDetail.minimal),
            zones: zones,
            planned: norwegian,
            vdot: vdot,
            briefingTemplate: 'Minimal says the next step only.',
          ),
          VoiceCoachPlan.build(
            settings: const AppSettings(voiceCoaching: false),
            zones: zones,
            planned: norwegian,
            vdot: vdot,
            briefingTemplate: 'Coaching is off.',
          ),
          VoiceCoachPlan.off,
        ];
        for (final c in cases) {
          expect(c.briefingTemplate, isNull);
          expect(c.briefingFallback, isNull);
          expect(c.sessionName, isNull);
          expect(c.reps, isNull);
          expect(c.plannedDistanceM, isNull);
        }
      },
    );
  });
}
