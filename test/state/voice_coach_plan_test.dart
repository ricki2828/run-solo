import 'package:flutter_test/flutter_test.dart';
import 'package:run_engine/run_engine.dart' as engine;
import 'package:run_solo/platform/gateway.dart';
import 'package:run_solo/state/settings.dart';
import 'package:run_solo/state/voice_coach_plan.dart';

engine.BlockSession _session(
  engine.BlockKind kind, {
  String? presetId,
  int? minutes,
}) => engine.BlockSession(
  id: 'w1s1',
  week: 1,
  dayOffset: 0,
  role: engine.BlockRole.values.first,
  kind: kind,
  reason: 'test',
  presetId: presetId,
  minutes: minutes,
);

void main() {
  final zones = engine.HrZones.percentMax(190);
  const vdot = 45.0;

  test('check-in metrics persist, default to all, and pass zones + keys', () {
    expect(const AppSettings().checkInMetrics, CheckInMetric.values);
    expect(AppSettings.fromJson(const {}).checkInMetrics, CheckInMetric.values);
    final back = AppSettings.fromJson(
      const AppSettings(
        checkInMetrics: [CheckInMetric.time, CheckInMetric.climb],
      ).toJson(),
    );
    expect(back.checkInMetrics, [CheckInMetric.time, CheckInMetric.climb]);
    expect(
      AppSettings.fromJson({
        'checkInMetrics': ['time', 'nonsense'],
      }).checkInMetrics,
      [CheckInMetric.time],
    );
    final c = VoiceCoachPlan.checkIn(settings: back, zones: zones);
    expect(c.metrics, ['time', 'climb', 'voice:coach']);
    expect(c.zoneBottomsBpm, [for (var z = 2; z <= 5; z++) zones.bottom(z)]);
  });

  test('settings persist, and an old file has coaching on at full detail', () {
    final back = AppSettings.fromJson(
      const AppSettings(
        voiceCoaching: false,
        coachingDetail: CoachingDetail.minimal,
      ).toJson(),
    );
    expect(back.voiceCoaching, isFalse);
    expect(back.coachingDetail, CoachingDetail.minimal);
    final old = AppSettings.fromJson(const {});
    expect(old.voiceCoaching, isTrue);
    expect(old.coachingDetail, CoachingDetail.full);
    expect(
      AppSettings.fromJson(const {'coachingDetail': 'loud'}).coachingDetail,
      CoachingDetail.full,
    );
  });

  test('off when voice cues are off, or voice coaching is', () {
    for (final s in [
      const AppSettings(cues: false),
      const AppSettings(voiceCoaching: false),
    ]) {
      final c = VoiceCoachPlan.build(
        settings: s,
        zones: zones,
        planned: _session(engine.BlockKind.easy),
        vdot: vdot,
      );
      expect(c.enabled, isFalse);
      expect(c.targetPaceSecPerKm, isNull);
      expect(c.plannedMaxZone, isNull);
    }
  });

  test(
    'plan easy: pace is a ceiling, zone drift against zone 2, full only',
    () {
      final session = _session(engine.BlockKind.easy);
      final c = VoiceCoachPlan.build(
        settings: const AppSettings(),
        zones: zones,
        planned: session,
        vdot: vdot,
      );
      expect(c.enabled, isTrue);
      expect(c.full, isTrue);
      expect(c.slowerIsFine, isTrue);
      expect(c.targetPaceSecPerKm, engine.BlockPaces.target(session, vdot));
      expect(c.plannedMaxZone, 2);
      expect(c.zoneBottomsBpm, [114.0, 133.0, 152.0, 171.0]);

      final minimal = VoiceCoachPlan.build(
        settings: const AppSettings(coachingDetail: CoachingDetail.minimal),
        zones: zones,
        planned: session,
        vdot: vdot,
      );
      expect(minimal.enabled, isTrue);
      expect(minimal.full, isFalse);
      expect(minimal.targetPaceSecPerKm, isNull);
      expect(minimal.plannedMaxZone, isNull);
    },
  );

  test('plan intervals and long: pace, no drift; long is a ceiling too', () {
    final tempo = VoiceCoachPlan.build(
      settings: const AppSettings(),
      zones: zones,
      planned: _session(engine.BlockKind.interval, presetId: 'tempo'),
      vdot: vdot,
    );
    expect(tempo.targetPaceSecPerKm, isNotNull);
    expect(tempo.slowerIsFine, isFalse);
    expect(tempo.plannedMaxZone, isNull);
    final long = VoiceCoachPlan.build(
      settings: const AppSettings(),
      zones: zones,
      planned: _session(engine.BlockKind.long),
      vdot: vdot,
    );
    expect(long.slowerIsFine, isTrue);
    expect(long.plannedMaxZone, isNull);
  });

  test('easy and long plan starts carry kind and planned minutes', () {
    for (final (kind, name) in [
      (engine.BlockKind.easy, 'easy'),
      (engine.BlockKind.long, 'long'),
    ]) {
      final c = VoiceCoachPlan.build(
        settings: const AppSettings(),
        zones: zones,
        planned: _session(kind, minutes: 45),
        vdot: vdot,
      );
      expect(c.plannedKind, name);
      expect(c.plannedMinutes, 45);
    }
  });

  test(
    'free, warned easy, goal, interval, no minutes and Minimal carry none',
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
        ),
        VoiceCoachPlan.build(
          settings: const AppSettings(),
          zones: zones,
          planned: _session(
            engine.BlockKind.interval,
            presetId: 'tempo',
            minutes: 30,
          ),
          vdot: vdot,
        ),
        VoiceCoachPlan.build(
          settings: const AppSettings(),
          zones: zones,
          planned: _session(engine.BlockKind.easy),
          vdot: vdot,
        ),
        VoiceCoachPlan.build(
          settings: const AppSettings(coachingDetail: CoachingDetail.minimal),
          zones: zones,
          planned: _session(engine.BlockKind.long, minutes: 60),
          vdot: vdot,
        ),
        VoiceCoachPlan.off,
      ];
      for (final c in cases) {
        expect(c.plannedKind, isNull);
        expect(c.plannedMinutes, isNull);
      }
    },
  );

  test('a goal run uses its own pace, not the plan estimate', () {
    final c = VoiceCoachPlan.build(
      settings: const AppSettings(),
      zones: zones,
      planned: _session(engine.BlockKind.goal),
      vdot: vdot,
      goalPaceSecPerKm: 295,
    );
    expect(c.targetPaceSecPerKm, 295);
    expect(c.slowerIsFine, isFalse);
  });

  test('no plan, no goal, no vdot: next step only', () {
    final c = VoiceCoachPlan.build(settings: const AppSettings(), zones: zones);
    expect(c.enabled, isTrue);
    expect(c.targetPaceSecPerKm, isNull);
    expect(c.plannedMaxZone, isNull);
    expect(
      VoiceCoachPlan.build(
        settings: const AppSettings(),
        zones: zones,
        planned: _session(engine.BlockKind.easy),
      ).targetPaceSecPerKm,
      isNull,
      reason: 'no vdot, no pace estimate',
    );
  });

  test('Home warned Start Easy run: drift against zone 2, no pace', () {
    final c = VoiceCoachPlan.build(
      settings: const AppSettings(),
      zones: zones,
      warnedEasy: true,
      vdot: vdot,
    );
    expect(c.plannedMaxZone, 2);
    expect(c.zoneBottomsBpm, [114.0, 133.0, 152.0, 171.0]);
    expect(c.targetPaceSecPerKm, isNull);
    expect(
      VoiceCoachPlan.build(
        settings: const AppSettings(coachingDetail: CoachingDetail.minimal),
        zones: zones,
        warnedEasy: true,
      ).plannedMaxZone,
      isNull,
      reason: 'Minimal is next step only',
    );
  });

  test('voice detail defaults to Coach, persists, and rides the check-in as a reserved key', () {
    expect(kVoiceDetailDefault, VoiceDetail.coach);
    expect(const AppSettings().voiceDetail, VoiceDetail.coach);
    expect(AppSettings.fromJson(const {}).voiceDetail, VoiceDetail.coach);
    expect(
      AppSettings.fromJson({'voiceDetail': 'nonsense'}).voiceDetail,
      VoiceDetail.coach,
    );
    final back = AppSettings.fromJson(
      const AppSettings(voiceDetail: VoiceDetail.minimal).toJson(),
    );
    expect(back.voiceDetail, VoiceDetail.minimal);
    expect(
      [for (final d in VoiceDetail.values) d.metricKey],
      ['voice:coach', 'voice:everything', 'voice:minimal'],
    );
    final c = VoiceCoachPlan.checkIn(settings: back, zones: zones);
    expect(c.metrics.last, 'voice:minimal');
    // Never a check-in metric: the picker lists CheckInMetric only.
    expect(
      CheckInMetric.values.map((m) => m.key),
      isNot(contains(startsWith(kVoiceDetailMetricPrefix))),
    );
  });
}
