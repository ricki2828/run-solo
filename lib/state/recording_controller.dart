/// View model for the Record screen. Dart is a viewer of the Kotlin run
/// (plan §2 rule 2): everything here is rebuilt from `status()` plus the
/// event stream, so a recreated UI redraws mid-run.
///
/// Timing rule (mirrors `RecorderCore.kt`): `elapsedMs` runs through pauses,
/// the phase countdown counts active time only and arrives on every tick as
/// `phaseRemainingMs`, so nothing here extrapolates it beyond the ≤ 500 ms
/// between ticks while recording. `status()` is re-read on every state /
/// phase transition and carries `mode` and the lap list, so a recreated UI
/// rebuilds the rep ghost too.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:run_engine/run_engine.dart' as engine;

import '../platform/gateway.dart';
import '../platform/session_codec.dart';
import 'zone_memento.dart';

/// One-time note when native reports `FaultKind.volumeKeyUnavailable`.
const String kVolumeKeyUnavailableNote =
    "On Android 14, volume-key laps aren't available. Use the lock-screen LAP.";

/// Reason under the disabled "Volume-key lap" toggle (Start, Settings).
const String kVolumeKeyToggleReason =
    'Off on Android 14. Use the lock-screen LAP.';

@immutable
class RecordingSnapshot {
  const RecordingSnapshot({
    this.state = RecorderState.idle,
    this.runId,
    this.mode = RecordMode.free,
    this.spec,
    this.phase = Phase.none,
    this.repIndex = 0,
    this.lapIndex = 0,
    this.elapsedMs = 0,
    this.lapElapsedMs = 0,
    this.phaseRemainingMs = 0,
    this.lapDistanceM = 0,
    this.totalDistanceM = 0,
    this.livePaceSecPerKm,
    this.hr,
    this.hrPaired = false,
    this.gpsAccuracyM,
    this.gpsLost = false,
    this.hadFix = false,
    this.repPaces = const [],
    this.zone = 0,
    this.fault,
    this.notice,
    this.discarded = false,
  });

  final RecorderState state;
  final String? runId;
  final RecordMode mode;

  /// The session being recorded (CONTRACT.md I1): an intervals spec runs
  /// timed phases; a Cooper or fartlek spec rides along for the file.
  final SessionSpec? spec;
  final Phase phase;

  /// 1-based rep in work / recovery; 0 in warm-up.
  final int repIndex;
  final int lapIndex;

  /// Wall time since start, pauses included.
  final int elapsedMs;
  final int lapElapsedMs;

  /// Countdown in a timed phase (active time); 0 in warm-up / cool-down / free.
  final int phaseRemainingMs;
  final double lapDistanceM;
  final double totalDistanceM;

  /// Kotlin rolling 15 s pace; null = no fix in the window.
  final double? livePaceSecPerKm;
  final int? hr;
  final bool hrPaired;
  final double? gpsAccuracyM;

  /// No usable fix right now.
  final bool gpsLost;

  /// At least one fix this run; before that the banner says "Waiting for GPS".
  final bool hadFix;

  /// Pace of each completed work rep (4x4) or lap (Laps run), s/km, for
  /// "last rep 4:46 ▲ 5 s". Empty in a Free run.
  final List<double> repPaces;

  /// HR zone 0–5 from the engine tracker (plan §18.1): hysteresis and dwell
  /// applied, so the background never flashes. 0 = no HR.
  final int zone;

  /// Journal / storage faults the runner must see; null when fine.
  final String? fault;

  /// A one-time, non-fatal note for this run (amber banner), e.g. Android 14
  /// giving the volume keys to another app's music.
  final String? notice;

  /// The service discarded the run (`FaultKind.startFailed`): leave the screen.
  final bool discarded;

  /// Timed interval phases (warm-up, reps, recoveries, cool-down).
  bool get isPreset => mode == RecordMode.intervals && spec != null;
  int get reps => isPreset ? spec!.repCount : 0;

  /// This rep's recovery length in ms; 0 when not timed.
  int get recoveryMs =>
      (spec?.timedSeconds(StepKind.recovery, repIndex) ?? 0) * 1000;

  /// Free runs have no lap input at all (plan §18.2).
  bool get lapsEnabled => switch (mode) {
    RecordMode.intervals || RecordMode.laps => true,
    RecordMode.free || RecordMode.cooper => false,
  };
  bool get recording => state == RecorderState.recording;
  bool get paused => state == RecorderState.paused;
  bool get active => recording || paused;
  bool get timed => phase == Phase.work || phase == Phase.recovery;
  bool get strapDropped => hrPaired && hr == null;

  /// Accuracy worse than 20 m is the amber state (design brief §4.4).
  bool get gpsWeak => gpsAccuracyM != null && gpsAccuracyM! > 20;
  double? get lastRepPaceSecPerKm => repPaces.isEmpty ? null : repPaces.last;

  RecordingSnapshot copyWith({
    RecorderState? state,
    String? runId,
    RecordMode? mode,
    SessionSpec? spec,
    Phase? phase,
    int? repIndex,
    int? lapIndex,
    int? elapsedMs,
    int? lapElapsedMs,
    int? phaseRemainingMs,
    double? lapDistanceM,
    double? totalDistanceM,
    double? livePaceSecPerKm,
    bool clearPace = false,
    int? hr,
    bool clearHr = false,
    bool? hrPaired,
    double? gpsAccuracyM,
    bool clearGps = false,
    bool? gpsLost,
    bool? hadFix,
    List<double>? repPaces,
    int? zone,
    String? fault,
    bool clearFault = false,
    String? notice,
    bool? discarded,
  }) => RecordingSnapshot(
    state: state ?? this.state,
    runId: runId ?? this.runId,
    mode: mode ?? this.mode,
    spec: spec ?? this.spec,
    phase: phase ?? this.phase,
    repIndex: repIndex ?? this.repIndex,
    lapIndex: lapIndex ?? this.lapIndex,
    elapsedMs: elapsedMs ?? this.elapsedMs,
    lapElapsedMs: lapElapsedMs ?? this.lapElapsedMs,
    phaseRemainingMs: phaseRemainingMs ?? this.phaseRemainingMs,
    lapDistanceM: lapDistanceM ?? this.lapDistanceM,
    totalDistanceM: totalDistanceM ?? this.totalDistanceM,
    livePaceSecPerKm: clearPace
        ? null
        : (livePaceSecPerKm ?? this.livePaceSecPerKm),
    hr: clearHr ? null : (hr ?? this.hr),
    hrPaired: hrPaired ?? this.hrPaired,
    gpsAccuracyM: clearGps ? null : (gpsAccuracyM ?? this.gpsAccuracyM),
    gpsLost: gpsLost ?? this.gpsLost,
    hadFix: hadFix ?? this.hadFix,
    repPaces: repPaces ?? this.repPaces,
    zone: zone ?? this.zone,
    fault: clearFault ? null : (fault ?? this.fault),
    notice: notice ?? this.notice,
    discarded: discarded ?? this.discarded,
  );
}

class RecordingController extends ChangeNotifier {
  RecordingController(
    this._gateway, {
    DateTime Function()? now,
    int Function()? maxHr,
    ZoneMementoStore? zoneMemento,
  }) : _now = now ?? DateTime.now,
       _maxHr = maxHr ?? (() => 190),
       _zoneMemento = zoneMemento ?? MemoryZoneMementoStore();

  final RecorderGateway _gateway;
  final DateTime Function() _now;

  /// Resolved max HR (plan D3 `maxHrFor`), read when a run starts or the
  /// screen re-attaches; a mid-run settings change applies on the next run.
  final int Function() _maxHr;

  /// The engine's zone tracker (plan §18.1): hysteresis, dwell, loss and
  /// first-sample rules live there, fixture-tested; this only feeds ticks.
  engine.HrZoneTracker? _tracker;

  /// Last zone of the live run on disk, for a recreated isolate (W4).
  final ZoneMementoStore _zoneMemento;

  RecordingSnapshot _snap = const RecordingSnapshot();
  RecordingSnapshot get snapshot => _snap;

  /// Bumps on every lap from any source, so the LAP ring (M2) also confirms
  /// notification and volume-key laps.
  final ValueNotifier<int> lapPulse = ValueNotifier(0);

  /// Bumps when a work rep ends (M3 invert + long pulse).
  final ValueNotifier<int> repCompletePulse = ValueNotifier(0);

  /// Bumps when a recovery ends ("Rep n, go": single pulse).
  final ValueNotifier<int> repStartPulse = ValueNotifier(0);

  StreamSubscription<RecorderEvent>? _sub;

  /// Cumulative distance at the previous lap, for the lap distance delta.
  double _lastLapDistanceM = 0;
  DateTime? _lastTickAt;
  Future<void>? _refreshing;

  /// Subscribe and redraw from `status()`; safe to call again after the
  /// Activity is recreated.
  Future<void> attach() async {
    _sub ??= _gateway.events.listen(_onEvent);
    if (_tracker == null) {
      // Recreated isolate (W4): `status()` carries no HR, so the last zone
      // comes from the memento the previous isolate wrote for this run.
      // Seed the tracker and paint that zone before the first tick.
      final status = await _gateway.status();
      final m = await _zoneMemento.load();
      final live =
          status.state == RecorderState.recording ||
          status.state == RecorderState.paused;
      if (live && m != null && m.runId == status.runId && m.zone > 0) {
        _tracker = engine.HrZoneTracker.seeded(
          maxHr: _maxHr().toDouble(),
          zone: m.zone,
          hr: m.hr,
          atMs: m.elapsedMs,
        );
        _snap = _snap.copyWith(zone: m.zone, runId: status.runId);
        notifyListeners();
      } else {
        _tracker = engine.HrZoneTracker(maxHr: _maxHr().toDouble());
      }
    }
    await refreshStatus();
  }

  /// One in-flight read at a time; a burst of transitions coalesces.
  Future<void> refreshStatus() {
    return _refreshing ??= _readStatus().whenComplete(() => _refreshing = null);
  }

  Future<void> _readStatus() async {
    final s = await _gateway.status();
    if (s.laps.isNotEmpty) {
      final last = s.laps.last;
      _lastLapDistanceM = last.distanceM;
    }
    _snap = _snap.copyWith(
      state: s.state,
      runId: s.runId,
      mode: s.state == RecorderState.idle ? _snap.mode : s.mode,
      spec: s.spec,
      repPaces: repPacesFromLaps(
        s.laps,
        s.mode == RecordMode.intervals ? s.spec : null,
      ),
      phase: s.phase,
      repIndex: s.repIndex,
      lapIndex: s.lapIndex,
      elapsedMs: s.elapsedMs,
      phaseRemainingMs: s.phaseRemainingMs,
      hrPaired: s.hrConnected || _snap.hrPaired,
      gpsLost: !s.gpsFix,
      hadFix: _snap.hadFix || s.gpsFix,
      fault: s.journalOk ? null : 'Journal write failed',
      clearFault: s.journalOk,
    );
    notifyListeners();
  }

  Future<StartResult> start(
    RecordMode mode,
    SessionSpec? spec,
    Units units, {
    LiveContext? liveContext,
  }) async {
    final result = await _gateway.start(
      mode,
      spec,
      units,
      liveContext: liveContext,
    );
    if (result.error == null || result.error == StartError.alreadyRunning) {
      _reset(mode, spec);
      await attach();
    }
    return result;
  }

  /// After `resumeRecovered` succeeded on the gateway.
  Future<void> attachResumed(RecordMode mode) async {
    _reset(mode, null);
    await attach();
  }

  void _reset(RecordMode mode, SessionSpec? spec) {
    _lastLapDistanceM = 0;
    _tracker = engine.HrZoneTracker(maxHr: _maxHr().toDouble());
    _snap = RecordingSnapshot(
      mode: mode,
      spec: switch (mode) {
        RecordMode.intervals || RecordMode.cooper || RecordMode.laps => spec,
        RecordMode.free => null,
      },
      hrPaired: _snap.hrPaired,
    );
  }

  /// No-op in a Free run (plan §18.2: lap input disabled; the service would
  /// ignore it too, this just avoids the round trip).
  Future<void> lap() =>
      _snap.lapsEnabled ? _gateway.lap(LapSource.button) : Future.value();

  /// "Start 4x4" in warm-up; nothing otherwise.
  Future<void> startReps() => _snap.isPreset && _snap.phase == Phase.warmup
      ? _gateway.startReps()
      : Future.value();
  Future<void> pause() => _gateway.pause();
  Future<void> resume() => _gateway.resume();

  /// Throws what the platform throws; the screen decides what to show.
  Future<String?> stop() async {
    final id = await _gateway.stop();
    unawaited(_zoneMemento.save(null));
    _snap = _snap.copyWith(state: RecorderState.idle);
    notifyListeners();
    return id;
  }

  /// Elapsed / remaining interpolated between ≤ 2 Hz ticks so the timer
  /// digits change every second even when the service is coarse. Frozen
  /// while paused.
  int get displayElapsedMs => _snap.elapsedMs + _sinceTickMs();

  int get displayRemainingMs =>
      (_snap.phaseRemainingMs - _sinceTickMs()).clamp(0, 1 << 31);

  int get displayLapElapsedMs => _snap.lapElapsedMs + _sinceTickMs();

  int _sinceTickMs() {
    final at = _lastTickAt;
    if (at == null || !_snap.recording) return 0;
    return _now().difference(at).inMilliseconds.clamp(0, 2000);
  }

  void _onEvent(RecorderEvent e) {
    switch (e) {
      case TickEvent():
        _onTick(e);
      case LapEvent():
        _onLap(e);
      case PhaseEvent():
        _onPhase(e);
      case StateEvent():
        _onState(e);
      case CueEvent():
        break; // audio + haptics are the service's job (plan §3)
      case FaultEvent():
        _onFault(e);
    }
    notifyListeners();
  }

  void _onTick(TickEvent t) {
    _lastTickAt = _now();
    final fix = t.gpsAccuracyM != null;
    final update = (_tracker ??= engine.HrZoneTracker(
      maxHr: _maxHr().toDouble(),
    )).update(t.elapsedMs, t.hr);
    final zone = update.state.zone;
    if (update.changed && _snap.runId != null) {
      unawaited(
        _zoneMemento.save(
          ZoneMemento(
            runId: _snap.runId!,
            zone: zone,
            hr: t.hr,
            elapsedMs: t.elapsedMs,
          ),
        ),
      );
    }
    _snap = _snap.copyWith(
      state: t.state,
      phase: t.phase,
      repIndex: t.repIndex,
      elapsedMs: t.elapsedMs,
      lapElapsedMs: t.lapElapsedMs,
      lapDistanceM: t.lapDistanceM,
      totalDistanceM: t.totalDistanceM,
      livePaceSecPerKm: t.lapPaceLiveSecPerKm,
      clearPace: t.lapPaceLiveSecPerKm == null,
      hr: t.hr,
      clearHr: t.hr == null,
      hrPaired: _snap.hrPaired || t.hr != null,
      gpsAccuracyM: t.gpsAccuracyM,
      clearGps: !fix,
      gpsLost: !fix,
      hadFix: _snap.hadFix || fix,
      phaseRemainingMs: t.phaseRemainingMs,
      zone: zone,
    );
  }

  void _onLap(LapEvent l) {
    // distanceM is cumulative run distance (RecordingSession.kt), so the
    // lap's own distance is a delta; activeMs is the lap's duration without
    // pauses and kill gaps (tMs stays wall time).
    final lapDistanceM = l.distanceM - _lastLapDistanceM;
    final lapMs = l.activeMs;
    _lastLapDistanceM = l.distanceM;
    final paces = List.of(_snap.repPaces);
    final counts = switch (_snap.mode) {
      RecordMode.intervals => _snap.phase == Phase.work,
      RecordMode.laps => true,
      RecordMode.free || RecordMode.cooper => false,
    };
    if (counts && lapDistanceM > 0 && lapMs > 0) {
      paces.add(lapMs / 1000 / (lapDistanceM / 1000));
    }
    _snap = _snap.copyWith(
      lapIndex: l.index + 1,
      lapElapsedMs: 0,
      lapDistanceM: 0,
      repPaces: paces,
    );
    lapPulse.value += 1;
  }

  void _onPhase(PhaseEvent p) {
    final previous = _snap.phase;
    _snap = _snap.copyWith(
      phase: p.phase,
      repIndex: p.repIndex,
      phaseRemainingMs: p.phaseDurationMs,
    );
    if (previous == Phase.work &&
        (p.phase == Phase.recovery || p.phase == Phase.cooldown)) {
      repCompletePulse.value += 1;
    } else if (previous == Phase.recovery && p.phase == Phase.work) {
      repStartPulse.value += 1;
    }
    // Laps + remaining from the service (a manual lap mid-phase re-aligns).
    unawaited(refreshStatus());
  }

  void _onState(StateEvent s) {
    _snap = _snap.copyWith(state: s.state, runId: s.runId, phase: s.phase);
    // Idle is final: the run is finalised, nothing left to read (and a late
    // read could still answer `finalising`).
    if (s.state != RecorderState.idle) unawaited(refreshStatus());
  }

  void _onFault(FaultEvent f) {
    _snap = switch (f.kind) {
      FaultKind.gpsLost => _snap.copyWith(gpsLost: true, clearGps: true),
      // Debug-only signal that a LAP reached Free mode; the screen has no LAP there.
      FaultKind.gpsWeak || FaultKind.lapIgnored => _snap,
      // Android 14 never routes volume keys to an app's session, so native
      // registers none and fires this once; the lock-screen LAP still works.
      FaultKind.volumeKeyUnavailable => _snap.copyWith(
        notice: kVolumeKeyUnavailableNote,
      ),
      FaultKind.hrDisconnected => _snap.copyWith(clearHr: true),
      FaultKind.journalWriteFailed ||
      FaultKind.lowStorage ||
      FaultKind.osKilledMidRun => _snap.copyWith(fault: f.message),
      FaultKind.startFailed => _snap.copyWith(
        fault: f.message,
        discarded: true,
        state: RecorderState.idle,
      ),
    };
  }

  /// Work-rep paces from the service's lap list (cumulative `distanceM`,
  /// active-time `activeMs`). With an intervals spec, lap 0 ends the
  /// warm-up and phases then alternate, so odd indices end work reps up to
  /// the last rep (index 2·reps − 1). Without one (Laps run) every lap
  /// counts; Free runs have no laps.
  static List<double> repPacesFromLaps(
    List<LapSummary> laps,
    SessionSpec? spec,
  ) {
    if (laps.isEmpty) return const [];
    final out = <double>[];
    var prevD = 0.0;
    for (final l in laps) {
      final ms = l.activeMs;
      final m = l.distanceM - prevD;
      prevD = l.distanceM;
      final counts =
          spec == null || (l.index.isOdd && l.index <= 2 * spec.repCount);
      if (counts && ms > 0 && m > 0) out.add(ms / 1000 / (m / 1000));
    }
    return out;
  }

  @override
  void dispose() {
    _sub?.cancel();
    lapPulse.dispose();
    repCompletePulse.dispose();
    repStartPulse.dispose();
    super.dispose();
  }
}
