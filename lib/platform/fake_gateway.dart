/// In-process stand-ins for the Kotlin side. Used by widget tests and by the
/// APK when built with `--dart-define=RUN_SOLO_FAKE=true`.
///
/// The fake recorder mirrors `RecorderCore.kt` + `RecordingSession.kt`
/// (see the semantics list in `gateway.dart`): elapsed runs through pauses
/// while phase timers count active time only; ticks keep coming while paused;
/// `LapEvent.distanceM` is cumulative; `repIndex` is 1-based and the last
/// rep goes straight to cool-down (no recovery after it); `StateEvent` / `PhaseEvent` fire
/// on every transition; volume-key laps never re-align a preset.
library;

import 'dart:async';
import 'dart:math' as math;

import 'package:run_engine/run_engine.dart' as engine;

import 'gateway.dart';
import 'session_codec.dart';

/// A finalised run as the fake remembers it (the real app reads run files).
class FakeFinalisedRun {
  FakeFinalisedRun({
    required this.runId,
    required this.mode,
    required this.start,
    required this.durationMs,
    required this.distanceM,
    required this.laps,
    this.spec,
  });
  final String runId;
  final RecordMode mode;
  final DateTime start;
  final int durationMs;
  final double distanceM;
  final int laps;
  final SessionSpec? spec;
}

class FakeRecorderGateway implements RecorderGateway {
  FakeRecorderGateway({
    this.autoTick = false,
    this.tickInterval = const Duration(milliseconds: 500),
    DateTime Function()? now,
    List<OrphanJournal>? orphans,
    this.startError,
  }) : _now = now ?? DateTime.now,
       orphans = orphans ?? [];

  /// Advance on a wall-clock timer (the APK); tests call [advance] instead.
  final bool autoTick;
  final Duration tickInterval;
  final DateTime Function() _now;

  /// Returned by [recover] until resumed, finalised or discarded.
  final List<OrphanJournal> orphans;

  /// When set, [start] / [resumeRecovered] fail with this error.
  StartError? startError;

  /// Runs finalised by [stop] / [finalise], newest last.
  final List<FakeFinalisedRun> finalised = [];

  /// Journals removed by [discardJournal].
  final List<String> discarded = [];

  /// Lap presses swallowed because the run is a Free run.
  int lapsIgnored = 0;

  /// RecordingSession since I2: a manual lap's [LapEvent] (and the
  /// [PhaseEvent] it causes) waits for the next tick, and a [LapPendingEvent]
  /// goes out at the press. Off by default: older tests expect the instant
  /// lap.
  bool deferManualLaps = false;

  /// The next deferred [LapEvent] is never sent (the lap is still in
  /// `status().laps`), for the controller's reconcile path.
  bool dropNextDeferredLap = false;

  bool _holding = false;
  final List<RecorderEvent> _deferred = [];

  /// Scripted fault of any kind (tests for the one-time notices).
  void emitFault(FaultKind kind, String message) =>
      _emit(FaultEvent(kind: kind, message: message));

  /// Scripted HR for the next ticks (null = the phase-based default). Zone
  /// tests drive the tracker through this.
  int? scriptedHr;

  /// Scripted faults. Toggling on emits the matching [FaultEvent] once.
  bool get gpsLost => _gpsLost;
  set gpsLost(bool v) {
    if (v == _gpsLost) return;
    _gpsLost = v;
    if (v) _emit(FaultEvent(kind: FaultKind.gpsLost, message: 'No GPS fix'));
  }

  bool get strapDropped => _strapDropped;
  set strapDropped(bool v) {
    if (v == _strapDropped) return;
    _strapDropped = v;
    if (v) {
      _emit(
        FaultEvent(kind: FaultKind.hrDisconnected, message: 'Strap dropped'),
      );
    }
  }

  /// Simulated horizontal accuracy in metres (null while [gpsLost]).
  double gpsAccuracyM = 8;
  bool hrPaired = true;
  bool cuesEnabled = true;

  /// Rolling live pace the fake reports, s/km. Tests script "vs last rep".
  double liveSecPerKm = 285;

  bool _gpsLost = false;
  bool _strapDropped = false;
  final _controller = StreamController<RecorderEvent>.broadcast();
  Timer? _timer;
  int _runCounter = 0;
  final _rng = math.Random(7);

  // Live run state (mirrors RecorderCore).
  RecorderState _state = RecorderState.idle;
  String? _runId;
  RecordMode _mode = RecordMode.free;
  SessionSpec? _spec;

  /// Interval phases run only for an intervals spec (Cooper is one timed
  /// work step with no phases in I1; fartlek is Laps).
  SessionSpec? get _timed => _mode == RecordMode.intervals ? _spec : null;
  DateTime? _startedAt;
  int _elapsedMs = 0; // wall time incl. pauses
  int _activeMs = 0; // recording time only
  int _lapStartElapsedMs = 0;
  int _lapStartActiveMs = 0;
  double _lapStartDistanceM = 0;
  double _totalDistanceM = 0;
  int _lapIndex = 0;
  final List<LapSummary> _laps = [];
  Phase _phase = Phase.none;
  int _repIndex = 0;
  int? _phaseDurationMs;

  /// Metres a distance step runs to (null for time steps and open phases).
  /// Plan §3.6: the step ends at the first sample at or past it; with no
  /// fix it never ends on its own and is never time-extrapolated (W3).
  double? _phaseTargetM;

  /// Active time of the last work step, for an equal-time recovery (Yasso).
  int _lastWorkActiveMs = 0;
  int _phaseStartActiveMs = 0;
  bool _halfwayCued = false;
  bool _thirtyCued = false;

  @override
  Stream<RecorderEvent> get events => _controller.stream;

  RecorderState get state => _state;
  Phase get phase => _phase;
  int get repIndex => _repIndex;
  int get elapsedMs => _elapsedMs;
  int get phaseRemainingMs => _remaining;

  int get _remaining {
    final d = _phaseDurationMs;
    if (d == null) return 0;
    return math.max(0, d - (_activeMs - _phaseStartActiveMs));
  }

  @override
  Future<StartResult> start(
    RecordMode mode,
    SessionSpec? spec,
    Units units, {
    LiveContext? liveContext,
  }) async {
    startCalls.add((mode: mode, spec: spec, liveContext: liveContext));
    gpsProbeRunning = false; // as native: any start ends the probe
    if (startError != null) return StartResult(error: startError);
    if (_state != RecorderState.idle) {
      return StartResult(runId: _runId, error: StartError.alreadyRunning);
    }
    _runCounter += 1;
    _begin(
      'fake-${_runCounter.toString().padLeft(3, '0')}',
      mode,
      switch (mode) {
        RecordMode.intervals || RecordMode.cooper || RecordMode.laps => spec,
        RecordMode.free => null,
      },
    );
    return StartResult(runId: _runId);
  }

  /// Every `start` call, for tests that check what the app sent.
  final List<({RecordMode mode, SessionSpec? spec, LiveContext? liveContext})>
  startCalls = [];

  void _begin(String runId, RecordMode mode, SessionSpec? spec) {
    _runId = runId;
    _mode = mode;
    _spec = spec;
    _startedAt = _now();
    _elapsedMs = 0;
    _activeMs = 0;
    _lapStartElapsedMs = 0;
    _lapStartActiveMs = 0;
    _lapStartDistanceM = 0;
    _totalDistanceM = 0;
    _lapIndex = 0;
    _laps.clear();
    _repIndex = 0;
    _phaseDurationMs = null;
    _phaseTargetM = null;
    _lastWorkActiveMs = 0;
    _phase = Phase.none;
    _state = RecorderState.recording;
    _emitState();
    if (_timed != null && _timed!.warmupSeconds == 0) {
      // No warm-up (parkrun): step 1 starts at Start, no warm-up lap.
      _enter(Phase.work, 1);
    } else if (_timed != null) {
      _phase = Phase.warmup;
      // A fixed warm-up counts down and starts rep 1 on its own.
      final w = _timed!.warmupSeconds;
      _phaseDurationMs = w == null ? null : w * 1000;
      _phaseStartActiveMs = 0;
      _emit(
        PhaseEvent(
          phase: _phase,
          repIndex: 0,
          phaseDurationMs: _phaseDurationMs ?? 0,
        ),
      );
    }
    if (autoTick) {
      _timer = Timer.periodic(tickInterval, (_) => advance(tickInterval));
    }
    _emitTick();
  }

  @override
  Future<void> pause() async {
    if (_state != RecorderState.recording) return;
    _state = RecorderState.paused;
    _emitState();
    _emitTick();
  }

  @override
  Future<void> resume() async {
    if (_state != RecorderState.paused) return;
    _state = RecorderState.recording;
    _emitState();
    _emitTick();
  }

  /// Same transition as the first LAP press in warm-up; ignored elsewhere.
  @override
  Future<void> startReps() async {
    if (_state != RecorderState.recording || _phase != Phase.warmup) return;
    startRepsCalls += 1;
    _manualLap(LapSource.button, () => _enter(Phase.work, 1));
  }

  /// One accepted manual lap: instant, or held for the next tick with a
  /// [LapPendingEvent] now ([deferManualLaps]).
  void _manualLap(LapSource source, void Function() realign) {
    if (!deferManualLaps) {
      _emitLap(source);
      realign();
      return;
    }
    final endedPhase = _phase;
    final endedRep = _repIndex;
    final index = _lapIndex;
    final tMs = _elapsedMs;
    final activeMs = _activeMs - _lapStartActiveMs;
    _holding = true;
    _emitLap(source);
    realign();
    _holding = false;
    final next = _deferred.whereType<PhaseEvent>().firstOrNull;
    _emit(
      LapPendingEvent(
        index: index,
        tMs: tMs,
        activeMs: activeMs,
        source: source,
        endedPhase: endedPhase,
        endedRepIndex: endedRep,
        nextPhase: next?.phase,
        nextRepIndex: next?.repIndex,
        nextPhaseDurationMs: next?.phaseDurationMs,
      ),
    );
    if (dropNextDeferredLap) {
      dropNextDeferredLap = false;
      _deferred.removeWhere((e) => e is LapEvent);
    }
  }

  void _flushDeferred() {
    final out = List.of(_deferred);
    _deferred.clear();
    out.forEach(_emit);
  }

  int startRepsCalls = 0;

  @override
  Future<void> lap(LapSource source) async {
    if (_state != RecorderState.recording) return;
    // Plan §18.2: Free run has no lap input at all; the service ignores any
    // press (debug builds log `lapIgnored`), nothing is recorded.
    switch (_mode) {
      case RecordMode.free:
        lapsIgnored += 1;
        return;
      case RecordMode.intervals:
      case RecordMode.laps:
      case RecordMode.cooper:
        break;
    }
    // RecorderCore default config: volume-key laps only in Laps mode (W8);
    // in a preset they are ignored outright, never recorded or re-aligned.
    if (_timed != null && source == LapSource.volumeKey) return;
    _manualLap(source, () {
      if (_timed == null) return;
      switch (_phase) {
        case Phase.warmup:
          _enter(Phase.work, 1);
        case Phase.work:
        case Phase.recovery:
          // Ends the step early, a distance step included (END REP, W3).
          _advancePhase();
        case Phase.cooldown:
        case Phase.none:
          break;
      }
    });
  }

  @override
  Future<String?> stop() async {
    if (_state == RecorderState.idle) return null;
    _timer?.cancel();
    _timer = null;
    _flushDeferred(); // RecordingSession.stop flushes held laps too
    _state = RecorderState.finalising;
    _phase = Phase.none;
    _emitState();
    final id = _runId!;
    finalised.add(
      FakeFinalisedRun(
        runId: id,
        mode: _mode,
        start: _startedAt!,
        durationMs: _elapsedMs,
        distanceM: _totalDistanceM,
        laps: _lapIndex,
        spec: _spec,
      ),
    );
    _state = RecorderState.idle;
    _emit(CueEvent(kind: CueKind.stop));
    _emitState();
    _runId = null;
    return id;
  }

  @override
  Future<RecorderStatus> status() async => RecorderStatus(
    state: _state,
    runId: _runId,
    elapsedMs: _state == RecorderState.idle ? 0 : _elapsedMs,
    lapIndex: _lapIndex,
    gpsFix: !_gpsLost,
    hrConnected: hrPaired && !_strapDropped,
    phase: _phase,
    repIndex: _repIndex,
    phaseRemainingMs: _remaining,
    spec: _state == RecorderState.idle ? null : _spec,
    stepIndex: _stepIndex,
    stepRemainingMs: _phaseDurationMs == null || _stepIndex == null
        ? null
        : _remaining,
    stepRemainingM: _phaseTargetM == null
        ? null
        : math.max(0, _phaseTargetM! - _stepDistanceM),
    journalOk: true,
    mode: _state == RecorderState.idle ? RecordMode.free : _mode,
    laps: List.of(_laps),
  );

  @override
  Future<List<OrphanJournal>> recover() async => List.of(orphans);

  @override
  Future<String?> finalise(String runId) async {
    final orphan = orphans.where((o) => o.runId == runId).firstOrNull;
    if (orphan == null) return null;
    orphans.remove(orphan);
    finalised.add(
      FakeFinalisedRun(
        runId: runId,
        mode: orphan.mode,
        start: _now().subtract(
          Duration(milliseconds: orphan.lastLineAgeMs + orphan.elapsedMs),
        ),
        durationMs: orphan.elapsedMs,
        distanceM: orphan.elapsedMs / 300,
        laps: 4,
      ),
    );
    return 'runs/run-$runId.json.gz';
  }

  @override
  Future<void> discardJournal(String runId) async {
    orphans.removeWhere((o) => o.runId == runId);
    discarded.add(runId);
  }

  @override
  Future<StartResult> resumeRecovered(String runId) async {
    if (startError != null) return StartResult(error: startError);
    if (_state != RecorderState.idle) {
      return StartResult(runId: _runId, error: StartError.alreadyRunning);
    }
    final orphan = orphans.where((o) => o.runId == runId).firstOrNull;
    if (orphan == null || !orphan.readable) {
      return StartResult(error: StartError.noSuchJournal);
    }
    orphans.remove(orphan);
    _begin(
      runId,
      orphan.mode,
      orphan.mode == RecordMode.intervals
          ? engine.SessionCatalogue.norwegian4x4.defaults.toPigeon()
          : null,
    );
    // The journal already held run time (a gap line covers the dark span,
    // so the phase clock does not count it).
    _elapsedMs = orphan.elapsedMs;
    _activeMs = orphan.elapsedMs;
    _totalDistanceM = orphan.elapsedMs / 300;
    _lapStartElapsedMs = _elapsedMs;
    _lapStartActiveMs = _activeMs;
    _lapStartDistanceM = _totalDistanceM;
    if (_timed != null) _enter(Phase.work, 1);
    if (orphan.endedPaused) {
      _state = RecorderState.paused;
      _emitState();
    }
    _emitTick();
    return StartResult(runId: runId);
  }

  @override
  Future<void> setCues(bool enabled) async => cuesEnabled = enabled;

  /// Pre-start probe: running flag for tests; [emitGpsProbe] scripts readiness.
  bool gpsProbeRunning = false;

  @override
  Future<void> startGpsProbe() async => gpsProbeRunning = true;

  @override
  Future<void> stopGpsProbe() async => gpsProbeRunning = false;

  void emitGpsProbe(GpsProbeEvent e) => _emit(e);

  /// Last value passed to [setVolumeKeyLaps]; null until called.
  bool? volumeKeyLaps;

  @override
  Future<void> setVolumeKeyLaps(bool enabled) async => volumeKeyLaps = enabled;

  /// Move the fake clock. Wall time always advances; active time and
  /// distance only while recording. Emits one tick plus whatever the phase
  /// timer crossed on the way.
  void advance(Duration dt) {
    if (_state == RecorderState.idle || _state == RecorderState.finalising) {
      return;
    }
    // RecordingSession.flushLaps: held laps go out before this tick.
    _flushDeferred();
    var remaining = dt.inMilliseconds;
    if (_state == RecorderState.paused) {
      _elapsedMs += remaining;
      _emitTick();
      return;
    }
    while (remaining > 0) {
      final target = _phaseTargetM;
      final toBoundary = target != null
          ? (_gpsLost
                ? remaining
                : ((target - _stepDistanceM) * liveSecPerKm).ceil())
          : _phaseDurationMs == null
          ? remaining
          : _remaining;
      final step = toBoundary > 0 ? math.min(remaining, toBoundary) : remaining;
      _elapsedMs += step;
      _activeMs += step;
      if (!_gpsLost) _totalDistanceM += step / liveSecPerKm;
      remaining -= step;
      final ended = target != null
          ? !_gpsLost && _stepDistanceM >= target - 0.01
          : _phaseDurationMs != null && _remaining <= 0;
      if (_phaseDurationMs != null) _cueCountdown();
      if (ended) {
        _emit(CueEvent(kind: CueKind.phaseEnd));
        _emitLap(LapSource.auto);
        if (_phase == Phase.warmup) {
          _enter(Phase.work, 1);
        } else {
          _advancePhase();
        }
      }
    }
    _emitTick();
  }

  void _cueCountdown() {
    final d = _phaseDurationMs;
    if (d == null) return;
    if (!_halfwayCued && _remaining <= d ~/ 2) {
      _halfwayCued = true;
      _emit(CueEvent(kind: CueKind.halfway));
    }
    if (!_thirtyCued && _remaining <= 30000) {
      _thirtyCued = true;
      _emit(CueEvent(kind: CueKind.thirtySeconds));
    }
  }

  void _emitLap(LapSource source) {
    final activeMs = _activeMs - _lapStartActiveMs;
    _emit(
      LapEvent(
        index: _lapIndex,
        tMs: _elapsedMs,
        activeMs: activeMs,
        distanceM: _totalDistanceM, // cumulative, as RecordingSession emits
        source: source,
      ),
    );
    _laps.add(
      LapSummary(
        index: _lapIndex,
        tMs: _elapsedMs,
        activeMs: activeMs,
        distanceM: _totalDistanceM,
        source: source,
      ),
    );
    _lapIndex += 1;
    _lapStartElapsedMs = _elapsedMs;
    _lapStartActiveMs = _activeMs;
    _lapStartDistanceM = _totalDistanceM;
  }

  /// RecorderCore.advance: work → recovery (same rep), or cool-down after
  /// the last rep; recovery → next work.
  void _advancePhase() {
    final p = _timed;
    if (p == null) return;
    switch (_phase) {
      case Phase.work:
        if (_repIndex >= p.repCount) {
          _enter(Phase.cooldown, _repIndex);
        } else {
          _enter(Phase.recovery, _repIndex);
        }
      case Phase.recovery:
        _enter(Phase.work, _repIndex + 1);
      case Phase.warmup:
      case Phase.cooldown:
      case Phase.none:
        break;
    }
  }

  /// Distance since the current step began (the step's own lap).
  double get _stepDistanceM => _totalDistanceM - _lapStartDistanceM;

  /// 0-based index of the current step in `spec.steps`; null outside reps.
  int? get _stepIndex {
    final p = _timed;
    if (p == null) return null;
    final kind = switch (_phase) {
      Phase.work => StepKind.work,
      Phase.recovery => StepKind.recovery,
      _ => null,
    };
    if (kind == null) return null;
    final i = p.steps.indexWhere(
      (s) => s.kind == kind && s.repIndex == _repIndex,
    );
    return i < 0 ? null : i;
  }

  void _enter(Phase phase, int repIndex) {
    final p = _timed!;
    if (_phase == Phase.work) {
      _lastWorkActiveMs = _activeMs - _phaseStartActiveMs;
    }
    _phase = phase;
    _repIndex = repIndex;
    _phaseStartActiveMs = _activeMs;
    _halfwayCued = false;
    _thirtyCued = false;
    final kind = switch (phase) {
      Phase.work => StepKind.work,
      Phase.recovery => StepKind.recovery,
      _ => null,
    };
    final step = kind == null
        ? null
        : p.steps
              .where((s) => s.kind == kind && s.repIndex == repIndex)
              .firstOrNull;
    _phaseTargetM = step?.target == TargetKind.distance
        ? step!.value.toDouble()
        : null;
    _phaseDurationMs = switch (step?.target) {
      TargetKind.time => step!.value * 1000,
      TargetKind.equalToPreviousWork => _lastWorkActiveMs,
      TargetKind.distance || null => null,
    };
    _emit(
      PhaseEvent(
        phase: phase,
        repIndex: repIndex,
        phaseDurationMs: _phaseDurationMs ?? 0,
      ),
    );
    if (_phaseDurationMs != null) _emit(CueEvent(kind: CueKind.start));
  }

  void _emitState() =>
      _emit(StateEvent(state: _state, runId: _runId, phase: _phase));

  void _emitTick() {
    final jitter = (_rng.nextDouble() - 0.5) * 6;
    _emit(
      TickEvent(
        elapsedMs: _elapsedMs,
        lapElapsedMs: _elapsedMs - _lapStartElapsedMs,
        lapDistanceM: _totalDistanceM - _lapStartDistanceM,
        lapPaceLiveSecPerKm: _gpsLost ? null : liveSecPerKm + jitter,
        totalDistanceM: _totalDistanceM,
        hr: (!hrPaired || _strapDropped)
            ? null
            : (scriptedHr ?? _hrFor(_phase)),
        gpsAccuracyM: _gpsLost ? null : gpsAccuracyM,
        state: _state,
        phase: _phase,
        repIndex: _repIndex,
        phaseRemainingMs: _remaining,
        stepIndex: _stepIndex,
        stepRemainingMs: _phaseDurationMs == null || _stepIndex == null
            ? null
            : _remaining,
        stepRemainingM: _phaseTargetM == null
            ? null
            : math.max(0, _phaseTargetM! - _stepDistanceM),
      ),
    );
  }

  int _hrFor(Phase phase) => switch (phase) {
    Phase.work => 168 + _rng.nextInt(5),
    Phase.recovery => 140 + _rng.nextInt(5),
    _ => 120 + _rng.nextInt(5),
  };

  void _emit(RecorderEvent e) {
    if (_holding) {
      _deferred.add(e);
      return;
    }
    if (!_controller.isClosed) _controller.add(e);
  }

  Future<void> dispose() async {
    _timer?.cancel();
    await _controller.close();
  }
}

class FakeBleGateway implements BleGateway {
  FakeBleGateway({List<BleDevice>? devices, this.scanDelay = Duration.zero})
    : devices =
          devices ??
          [
            BleDevice(address: 'C4:2B:11:09:AA:01', name: 'WHOOP 4A0C2F'),
            BleDevice(address: 'F0:13:C3:5E:20:9B', name: 'Polar H10 9B2C'),
          ];

  final List<BleDevice> devices;
  final Duration scanDelay;
  BleDevice? paired;
  bool connected = false;
  int? lastHr;
  bool adapterOn = true;
  bool failNextPair = false;

  @override
  Future<List<BleDevice>> scan() async {
    if (scanDelay > Duration.zero) await Future<void>.delayed(scanDelay);
    return List.of(devices);
  }

  @override
  Future<void> pair(BleDevice device) async {
    if (failNextPair) {
      failNextPair = false;
      throw StateError('GATT 133');
    }
    paired = device;
    connected = true;
  }

  @override
  Future<void> forget() async {
    paired = null;
    connected = false;
  }

  @override
  Future<BleStatus> status() async => BleStatus(
    connected: connected,
    address: paired?.address,
    name: paired?.name,
    lastHr: connected ? lastHr : null,
    adapterOn: adapterOn,
  );
}

class FakeStorageGateway implements StorageGateway {
  FakeStorageGateway({this.archiveNext = const []});

  /// Ids the next [enforceBackupBudget] reports as archived.
  List<String> archiveNext;
  int enforceCalls = 0;
  int backedUpBytes = 0;

  @override
  Future<BackupStatus> backupStatus() async => BackupStatus(
    backedUpBytes: backedUpBytes,
    budgetBytes: 15 * 1024 * 1024,
    quotaBytes: 25 * 1024 * 1024,
    archivedRunCount: 0,
    overBudget: backedUpBytes > 15 * 1024 * 1024,
  );

  @override
  Future<List<String>> enforceBackupBudget() async {
    enforceCalls += 1;
    final out = List.of(archiveNext);
    archiveNext = const [];
    return out;
  }
}

class FakePermissionsGateway implements PermissionsGateway {
  FakePermissionsGateway({
    this.snapshot = const PermissionSnapshot(),
    this.denyLocation = false,
    this.grantCoarseOnly = false,
    this.denyNotifications = false,
    this.denyBluetooth = false,
    this.volumeKeyLaps = true,
  });

  PermissionSnapshot snapshot;

  /// False scripts an Android 14 phone (volume-key laps unavailable).
  bool volumeKeyLaps;
  bool denyLocation;
  bool grantCoarseOnly;
  bool denyNotifications;
  bool denyBluetooth;
  int batterySettingsOpened = 0;
  int appSettingsOpened = 0;
  final List<PermissionKind> requests = [];

  @override
  Future<PermissionSnapshot> status() async => snapshot;

  @override
  Future<bool> request(PermissionKind kind) async {
    requests.add(kind);
    switch (kind) {
      case PermissionKind.location:
        if (denyLocation) return false;
        snapshot = snapshot.copyWith(
          fineLocation: !grantCoarseOnly,
          coarseOnly: grantCoarseOnly,
          locationServicesOn: true,
        );
        return !grantCoarseOnly;
      case PermissionKind.notifications:
        if (denyNotifications) return false;
        snapshot = snapshot.copyWith(notifications: true);
        return true;
      case PermissionKind.bluetooth:
        if (denyBluetooth) return false;
        snapshot = snapshot.copyWith(bluetooth: true);
        return true;
    }
  }

  @override
  Future<void> openBatterySettings() async {
    batterySettingsOpened += 1;
  }

  int batteryExemptionRequests = 0;

  /// Scripted outcome of the system exemption dialog.
  bool grantBatteryExemption = true;

  /// Mirrors the real path: the page opens, nothing changes until the user
  /// returns; tests flip [snapshot] and resume the app.
  @override
  Future<bool> requestBatteryExemption() async {
    batteryExemptionRequests += 1;
    batterySettingsOpened += 1;
    return snapshot.batteryUnrestricted;
  }

  @override
  Future<void> openAppSettings() async => appSettingsOpened += 1;

  /// Last value passed to [setKeepScreenOn]; null until called.
  bool? keepScreenOn;

  @override
  Future<void> setKeepScreenOn(bool enabled) async => keepScreenOn = enabled;

  @override
  Future<bool> volumeKeyLapsSupported() async => volumeKeyLaps;
}
