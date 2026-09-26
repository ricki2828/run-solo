import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:run_solo/platform/gateway.dart';
import 'package:run_solo/screens/recording_screen.dart';
import 'package:run_solo/state/recording_controller.dart';

import '../helpers.dart';

/// Kotlin→Dart event contract (review P2-9c): the trace in
/// `packages/run_engine/test/fixtures/contract-events/events_4x4_pause_kill.ndjson`
/// is produced by the JVM harness that mirrors `RecordingSession` field for
/// field (same RecorderCore / SampleTicker / journal / restore), not captured
/// from a device EventChannel. CI diffs it against the core-jvm copy.
///
/// Scenario: synthetic 4x4 (4 × 4:00 / 3:00), notification LAP at 60 s, a
/// 20 s pause at rep 2 + 90 s, a kill at rep 3 + 60 s with a 30 s dark gap and
/// `resumeRecovered`, then stop 10 s into the cool-down (27:00).
const String tracePath =
    'packages/run_engine/test/fixtures/contract-events/events_4x4_pause_kill.ndjson';

/// Replays the trace as the Pigeon stream; `status()` answers with the most
/// recent `status` line, exactly as the service would at that moment.
class TraceGateway implements RecorderGateway {
  TraceGateway(this.lines);
  final List<Map<String, Object?>> lines;
  final _controller = StreamController<RecorderEvent>.broadcast();
  int _pos = 0;
  RecorderStatus _status = RecorderStatus(
    state: RecorderState.idle,
    elapsedMs: 0,
    lapIndex: 0,
    gpsFix: false,
    hrConnected: false,
    phase: Phase.none,
    repIndex: 0,
    phaseRemainingMs: 0,
    journalOk: true,
    mode: RecordMode.free,
    laps: const [],
  );

  static const cueKinds = {
    'start',
    'halfway',
    'thirtySeconds',
    'phaseEnd',
    'stop',
  };

  /// Play every line with `t <= untilMs`, letting the controller drain the
  /// stream and read `status()` after each one. The trace writes a `status`
  /// line after the transition it describes; a live `status()` call already
  /// reflects that transition, so each timestamp group's status lines are
  /// applied before its events are emitted.
  Future<void> playUntil(int untilMs) async {
    while (_pos < lines.length && (lines[_pos]['t'] as int) <= untilMs) {
      final t = lines[_pos]['t'] as int;
      var end = _pos;
      while (end < lines.length && lines[end]['t'] == t) {
        end++;
      }
      final group = lines.sublist(_pos, end);
      _pos = end;
      for (final e in group) {
        if (e['kind'] == 'status') _status = _parseStatus(e);
      }
      for (final e in group) {
        final kind = e['kind'] as String;
        if (kind == 'status') continue;
        _controller.add(_parseEvent(e, kind));
        for (var i = 0; i < 4; i++) {
          await Future<void>.delayed(Duration.zero);
        }
      }
    }
  }

  /// Like [playUntil], but stops right after the first line of [kind] (the
  /// rest of its timestamp group stays queued): the state between a press
  /// and its deferred lap line.
  Future<void> playThroughFirst(String kind) async {
    final j = lines.indexWhere((e) => e['kind'] == kind, _pos);
    expect(j, greaterThanOrEqualTo(0), reason: 'no $kind line left');
    final t = lines[j]['t'] as int;
    await playUntil(t - 1);
    for (var k = _pos; k < lines.length && lines[k]['t'] == t; k++) {
      if (lines[k]['kind'] == 'status') _status = _parseStatus(lines[k]);
    }
    for (; _pos <= j; _pos++) {
      final e = lines[_pos];
      final k = e['kind'] as String;
      if (k == 'status') continue;
      _controller.add(_parseEvent(e, k));
      for (var i = 0; i < 4; i++) {
        await Future<void>.delayed(Duration.zero);
      }
    }
  }

  RecorderEvent _parseEvent(Map<String, Object?> e, String kind) {
    switch (kind) {
      case 'tick':
        return TickEvent(
          elapsedMs: e['elapsedMs'] as int,
          lapElapsedMs: e['lapElapsedMs'] as int,
          lapDistanceM: (e['lapDistanceM'] as num).toDouble(),
          lapPaceLiveSecPerKm: (e['lapPaceLiveSecPerKm'] as num?)?.toDouble(),
          totalDistanceM: (e['totalDistanceM'] as num).toDouble(),
          hr: e['hr'] as int?,
          gpsAccuracyM: (e['gpsAccuracyM'] as num?)?.toDouble(),
          state: RecorderState.values.byName(e['state'] as String),
          phase: Phase.values.byName(e['phase'] as String),
          repIndex: e['repIndex'] as int,
          phaseRemainingMs: e['phaseRemainingMs'] as int,
          stepIndex: e['stepIndex'] as int?,
          stepRemainingMs: e['stepRemainingMs'] as int?,
          stepRemainingM: (e['stepRemainingM'] as num?)?.toDouble(),
        );
      case 'lap':
        return LapEvent(
          index: e['index'] as int,
          tMs: e['tMs'] as int,
          activeMs: e['activeMs'] as int,
          distanceM: (e['distanceM'] as num).toDouble(),
          source: LapSource.values.byName(e['source'] as String),
        );
      case 'lapPending':
        final next = e['nextPhase'] as String?;
        return LapPendingEvent(
          index: e['index'] as int,
          tMs: e['tMs'] as int,
          activeMs: e['activeMs'] as int,
          source: LapSource.values.byName(e['source'] as String),
          endedPhase: Phase.values.byName(e['endedPhase'] as String),
          endedRepIndex: e['endedRepIndex'] as int,
          nextPhase: next == null ? null : Phase.values.byName(next),
          nextRepIndex: e['nextRepIndex'] as int?,
          nextPhaseDurationMs: e['nextPhaseDurationMs'] as int?,
        );
      case 'phase':
        return PhaseEvent(
          phase: Phase.values.byName(e['phase'] as String),
          repIndex: e['repIndex'] as int,
          phaseDurationMs: e['phaseDurationMs'] as int,
        );
      case 'state':
        return StateEvent(
          state: RecorderState.values.byName(e['state'] as String),
          runId: e['runId'] as String?,
          phase: Phase.values.byName(e['phase'] as String),
        );
      case 'fault':
        // The fixture carries the enum in `fault` (older copies used `faultKind`).
        return FaultEvent(
          kind: FaultKind.values.byName(
            (e['fault'] ?? e['faultKind']) as String,
          ),
          message: e['message'] as String,
        );
      case 'cue':
        return CueEvent(kind: CueKind.values.byName(e['cue'] as String));
      default:
        // Older fixture copies wrote the cue name into `kind`.
        if (cueKinds.contains(kind)) {
          return CueEvent(kind: CueKind.values.byName(kind));
        }
        throw StateError('unknown trace line kind: $kind');
    }
  }

  /// The Pigeon SessionSpec as Kotlin writes it in the trace (flat,
  /// CONTRACT.md I1).
  SessionSpec _parseSpec(Map<String, Object?> j) => SessionSpec(
    templateId: j['templateId'] as String,
    templateVersion: j['templateVersion'] as int,
    name: j['name'] as String,
    warmupSeconds: j['warmupSeconds'] as int?,
    cooldownSeconds: j['cooldownSeconds'] as int?,
    lapLockout: j['lapLockout'] as bool,
    cueProfile: CueProfile.values.byName(j['cueProfile'] as String),
    hrBandLow: (j['hrBandLow'] as num?)?.toDouble(),
    hrBandHigh: (j['hrBandHigh'] as num?)?.toDouble(),
    steps: [
      for (final s
          in (j['steps'] as List<Object?>).cast<Map<String, Object?>>())
        SessionStep(
          kind: StepKind.values.byName(s['kind'] as String),
          target: TargetKind.values.byName(s['target'] as String),
          value: s['value'] as int,
          style: RecoveryStyle.values.byName(s['style'] as String),
          repIndex: s['repIndex'] as int,
        ),
    ],
  );

  RecorderStatus _parseStatus(Map<String, Object?> e) {
    final spec = e['spec'] as Map<String, Object?>?;
    return RecorderStatus(
      state: RecorderState.values.byName(e['state'] as String),
      runId: e['runId'] as String?,
      elapsedMs: e['elapsedMs'] as int,
      lapIndex: e['lapIndex'] as int,
      gpsFix: e['gpsFix'] as bool,
      hrConnected: e['hrConnected'] as bool,
      phase: Phase.values.byName(e['phase'] as String),
      repIndex: e['repIndex'] as int,
      phaseRemainingMs: e['phaseRemainingMs'] as int,
      spec: spec == null ? null : _parseSpec(spec),
      stepIndex: e['stepIndex'] as int?,
      stepRemainingMs: e['stepRemainingMs'] as int?,
      stepRemainingM: (e['stepRemainingM'] as num?)?.toDouble(),
      journalOk: e['journalOk'] as bool,
      mode: RecordMode.values.byName(e['mode'] as String),
      laps: [
        for (final l in e['laps'] as List<Object?>)
          LapSummary(
            index: (l as Map<String, Object?>)['index'] as int,
            tMs: l['tMs'] as int,
            activeMs: l['activeMs'] as int,
            distanceM: (l['distanceM'] as num).toDouble(),
            source: LapSource.values.byName(l['source'] as String),
          ),
      ],
    );
  }

  @override
  Stream<RecorderEvent> get events => _controller.stream;

  @override
  Future<RecorderStatus> status() async => _status;

  // The trace drives everything; controls are not part of this contract.
  @override
  Future<StartResult> start(
    RecordMode m,
    SessionSpec? s,
    Units u, {
    LiveContext? liveContext,
  }) => throw UnimplementedError();
  @override
  Future<void> pause() => throw UnimplementedError();
  @override
  Future<void> resume() => throw UnimplementedError();
  @override
  Future<void> lap(LapSource s) => throw UnimplementedError();

  @override
  Future<void> startReps() => throw UnimplementedError();
  @override
  Future<String?> stop() => throw UnimplementedError();
  @override
  Future<List<OrphanJournal>> recover() => throw UnimplementedError();
  @override
  Future<StartResult> resumeRecovered(String r) => throw UnimplementedError();
  @override
  Future<String?> finalise(String r) => throw UnimplementedError();
  @override
  Future<void> discardJournal(String r) => throw UnimplementedError();
  @override
  Future<void> setCues(bool e) => throw UnimplementedError();
  @override
  Future<void> setVolumeKeyLaps(bool e) => throw UnimplementedError();
}

/// Work-rep paces straight from the trace's `lap` lines: odd lap indices end
/// work reps, active time over the delta of the cumulative distance.
List<double> expectedRepPaces(List<Map<String, Object?>> lines) {
  final laps = lines.where((e) => e['kind'] == 'lap').toList();
  final out = <double>[];
  for (var i = 1; i < laps.length; i++) {
    if ((laps[i]['index'] as int).isOdd) {
      final ms = laps[i]['activeMs'] as int;
      final m =
          (laps[i]['distanceM'] as num) - (laps[i - 1]['distanceM'] as num);
      out.add(ms / 1000 / (m / 1000));
    }
  }
  return out;
}

void main() {
  late List<Map<String, Object?>> lines;
  late TraceGateway trace;
  late RecordingController ctl;

  setUpAll(() {
    final file = File(tracePath);
    expect(file.existsSync(), isTrue, reason: 'fixture missing: $tracePath');
    lines = file
        .readAsLinesSync()
        .where((l) => l.trim().isNotEmpty)
        .map((l) => jsonDecode(l) as Map<String, Object?>)
        .toList();
    expect(lines.length, greaterThan(1000));
  });

  setUp(() {
    trace = TraceGateway(lines);
    ctl = RecordingController(trace, now: now);
  });

  tearDown(() => ctl.dispose());

  test(
    'recorded 4x4 with pause and kill/resume drives the controller',
    () async {
      await ctl.attach(); // subscribes; status() is idle until the run starts
      await trace.playUntil(0); // phase warmup, status, state recording
      expect(ctl.snapshot.mode, RecordMode.intervals);
      expect(ctl.snapshot.reps, 4);
      expect(ctl.snapshot.spec?.templateId, 'norwegian-4x4');
      expect(phaseTitle(ctl.snapshot), 'WARM-UP');

      // Notification LAP at 60 s starts rep 1. The press (lapPending) shows
      // it at once, before the deferred lap line; the ring fires once.
      await trace.playThroughFirst('lapPending');
      expect(phaseTitle(ctl.snapshot), 'REP 1 OF 4 · 4:00');
      expect(ctl.lapPulse.value, 1);
      expect(ctl.snapshot.lapIndex, 1);
      expect(ctl.snapshot.phaseRemainingMs, 240000);
      await trace.playUntil(61000);
      expect(phaseTitle(ctl.snapshot), 'REP 1 OF 4 · 4:00');
      expect(ctl.lapPulse.value, 1);
      expect(ctl.snapshot.phaseRemainingMs, 239000);

      // Rep 1 ends at 300 s: auto lap, recovery, M3, rep pace from the delta of
      // the cumulative lap distance.
      await trace.playUntil(301000);
      expect(phaseTitle(ctl.snapshot), 'RECOVERY 1 OF 3 · JOG');
      expect(ctl.repCompletePulse.value, 1);
      expect(ctl.snapshot.repPaces, hasLength(1));
      expect(ctl.snapshot.repPaces.single, closeTo(238.4, 0.5));

      // Pause at rep 2 + 90 s: countdown frozen at 150 s while elapsed runs.
      await trace.playUntil(571000);
      expect(ctl.snapshot.paused, isTrue);
      expect(phaseTitle(ctl.snapshot), 'REP 2 OF 4 · 4:00');
      final frozen = ctl.snapshot.phaseRemainingMs;
      expect(frozen, 150000);
      await trace.playUntil(589000);
      expect(ctl.snapshot.paused, isTrue);
      expect(ctl.snapshot.phaseRemainingMs, frozen);
      expect(ctl.snapshot.elapsedMs, 589000);
      expect(ctl.displayRemainingMs, frozen, reason: 'no interpolation paused');

      // Resume at 590 s; rep 2 therefore ends at 740 s, not 720.
      await trace.playUntil(600000);
      expect(ctl.snapshot.recording, isTrue);
      expect(ctl.snapshot.phaseRemainingMs, 140000);
      await trace.playUntil(739000);
      expect(phaseTitle(ctl.snapshot), 'REP 2 OF 4 · 4:00');
      await trace.playUntil(741000);
      expect(phaseTitle(ctl.snapshot), 'RECOVERY 2 OF 3 · JOG');
      expect(ctl.snapshot.repPaces, hasLength(2));

      // Kill at rep 3 + 60 s, 30 s dark, resumeRecovered: elapsed jumps, the
      // countdown does not, the lap history survives.
      await trace.playUntil(979000);
      expect(ctl.snapshot.phaseRemainingMs, 181000);
      final fresh = RecordingController(trace, now: now); // recreated UI
      await fresh.attach();
      expect(
        fresh.snapshot.repPaces,
        hasLength(2),
        reason: 'from status().laps',
      );
      expect(phaseTitle(fresh.snapshot), 'REP 3 OF 4 · 4:00');
      await trace.playUntil(1011000);
      expect(fresh.snapshot.elapsedMs, greaterThanOrEqualTo(1010000));
      expect(fresh.snapshot.phaseRemainingMs, lessThanOrEqualTo(180000));
      expect(fresh.snapshot.phaseRemainingMs, greaterThanOrEqualTo(178000));
      expect(fresh.snapshot.recording, isTrue);
      expect(ctl.snapshot.phaseRemainingMs, fresh.snapshot.phaseRemainingMs);

      // Rep 3 ends at 1190 s (gap excluded from the phase clock); rep 4 goes
      // straight to cool-down (no recovery after the last rep); the run stops
      // at 27:00 with 8 laps.
      await trace.playUntil(1191000);
      expect(phaseTitle(fresh.snapshot), 'RECOVERY 3 OF 3 · JOG');
      await trace.playUntil(1371000);
      expect(phaseTitle(fresh.snapshot), 'REP 4 OF 4 · 4:00');
      await trace.playUntil(1611000);
      expect(phaseTitle(fresh.snapshot), 'COOL-DOWN');
      // Ghost paces use activeMs, so the 20 s pause in rep 2 and the 30 s
      // dark gap in rep 3 do not inflate them (every work lap is 240 s
      // active; wall spans are 260 s and 270 s).
      final paces = fresh.snapshot.repPaces;
      expect(paces, hasLength(4));
      final expected = expectedRepPaces(lines);
      for (var i = 0; i < 4; i++) {
        expect(paces[i], closeTo(expected[i], 0.01), reason: 'rep ${i + 1}');
      }
      final laps = lines.where((e) => e['kind'] == 'lap').toList();
      expect(laps[3]['activeMs'], 240000);
      expect((laps[3]['tMs'] as int) - (laps[2]['tMs'] as int), 260000);
      expect(laps[5]['activeMs'], 240000);
      expect((laps[5]['tMs'] as int) - (laps[4]['tMs'] as int), 270000);
      await trace.playUntil(1620000);
      expect(fresh.snapshot.state, RecorderState.idle);
      expect(fresh.snapshot.lapIndex, 8);
      expect(
        fresh.repCompletePulse.value,
        2,
        reason: 'reps 3 and 4 after attach',
      );
      expect(ctl.repCompletePulse.value, 4);
      expect(ctl.repStartPulse.value, 3);
      expect(ctl.lapPulse.value, 8);
      expect(ctl.snapshot.fault, isNull);
      fresh.dispose();
    },
  );

  test(
    'every recorded tick: the step on screen is native spec.steps[stepIndex] '
    '(recoveries counted), none in warm-up and cool-down',
    () async {
      await ctl.attach();
      final ticks = lines.where((e) => e['kind'] == 'tick').toList();
      var checked = 0;
      for (final e in ticks) {
        await trace.playUntil(e['t'] as int);
        final snap = ctl.snapshot;
        final i = e['stepIndex'] as int?;
        expect(snap.stepIndex, i, reason: 't=${e['t']}');
        if (i == null) {
          expect(snap.currentStep, isNull, reason: 't=${e['t']}');
        } else {
          expect(
            identical(snap.currentStep, snap.spec!.steps[i]),
            isTrue,
            reason: 't=${e['t']}',
          );
          expect(
            snap.currentStep!.kind,
            e['phase'] == 'work' ? StepKind.work : StepKind.recovery,
          );
          checked++;
        }
        // Time steps: no metres to go (stepRemainingM is null in a 4x4).
        expect(snap.metresToGo, isNull);
      }
      expect(checked, greaterThan(1000));
    },
  );
}
