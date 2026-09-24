// Pigeon definitions for the Flutter <-> Kotlin channel contract (plan §2).
// Regenerate with: dart run pigeon --input pigeons/platform_api.dart
// Generated files are committed; CI fails if they drift.
@ConfigurePigeon(
  PigeonOptions(
    dartOut: 'lib/platform/platform_api.g.dart',
    dartOptions: DartOptions(),
    kotlinOut:
        'android/app/src/main/kotlin/app/runsolo/platform/PlatformApi.g.kt',
    kotlinOptions: KotlinOptions(package: 'app.runsolo.platform'),
    dartPackageName: 'run_solo',
  ),
)
library;

import 'package:pigeon/pigeon.dart';

/// Mode picked at Start. Mirrors `RunMode` in `package:run_engine`.
enum RecordMode { fourByFour, free }

enum Units { km, mi }

enum RecorderState { idle, recording, paused, finalising }

/// Phase of a preset (4x4) run; `none` in free mode or outside a rep.
enum Phase { none, warmup, work, recovery, cooldown }

enum LapSource { button, notification, volumeKey, auto }

enum CueKind { halfway, thirtySeconds, phaseEnd, start, stop }

enum FaultKind {
  gpsLost,
  gpsWeak,
  hrDisconnected,
  journalWriteFailed,
  lowStorage,
}

/// Typed errors returned by `start` (plan §2). Never a stringly-typed map.
enum StartError {
  noFinePermission,
  approximateOnly,
  locationOff,
  lowStorage,
  notificationsDenied,
  alreadyRunning,
}

/// The 4x4 preset written into the file header; drives cues and the detector.
class Preset {
  Preset({
    required this.reps,
    required this.workSeconds,
    required this.recoverySeconds,
  });
  int reps;
  int workSeconds;
  int recoverySeconds;
}

class StartResult {
  StartResult({this.runId, this.error});
  String? runId;
  StartError? error;
}

/// Enough for a recreated UI to redraw mid-run.
class RecorderStatus {
  RecorderStatus({
    required this.state,
    this.runId,
    required this.elapsedMs,
    required this.lapIndex,
    required this.gpsFix,
    required this.hrConnected,
    required this.phase,
    required this.repIndex,
    required this.phaseRemainingMs,
    this.preset,
    required this.journalOk,
  });
  RecorderState state;
  String? runId;
  int elapsedMs;
  int lapIndex;
  bool gpsFix;
  bool hrConnected;
  Phase phase;
  int repIndex;
  int phaseRemainingMs;
  Preset? preset;
  bool journalOk;
}

/// An in-progress journal found on app open without a finalised run file.
class OrphanJournal {
  OrphanJournal({
    required this.runId,
    required this.lastLineAgeMs,
    required this.mode,
  });
  String runId;
  int lastLineAgeMs;
  RecordMode mode;
}

class BleDevice {
  BleDevice({required this.address, this.name});
  String address;
  String? name;
}

@HostApi()
abstract class RecorderApi {
  /// Idempotent: a second call while recording returns the running id.
  StartResult start(RecordMode mode, Preset? preset, Units units);
  void pause();
  void resume();
  void lap(LapSource source);

  /// Finalises in Kotlin (journal -> tmp -> fsync -> rename -> delete journal). No-op when idle.
  String? stop();
  RecorderStatus status();

  /// Called on app open: journals without a finalised file.
  List<OrphanJournal> recover();

  /// Finalise an orphaned journal without resuming it.
  void finalise(String runId);
  void setCues(bool enabled);
}

@HostApi()
abstract class BleApi {
  /// Scan once for Heart Rate Profile (0x180D) devices to pair.
  @async
  List<BleDevice> bleScan();
  void blePair(String address);
  void bleForget();
}

// --- Events (EventChannel, <= 2 Hz to the UI) ---

sealed class RecorderEvent {}

class TickEvent extends RecorderEvent {
  TickEvent({
    required this.elapsedMs,
    required this.lapElapsedMs,
    required this.lapDistanceM,
    this.lapPaceLiveSecPerKm,
    required this.totalDistanceM,
    this.hr,
    this.gpsAccuracyM,
    required this.state,
  });
  int elapsedMs;
  int lapElapsedMs;
  double lapDistanceM;

  /// Rolling 15 s "live" pace; differs from the verdict's trimmed pace.
  double? lapPaceLiveSecPerKm;
  double totalDistanceM;
  int? hr;
  double? gpsAccuracyM;
  RecorderState state;
}

class LapEvent extends RecorderEvent {
  LapEvent({
    required this.index,
    required this.tMs,
    required this.distanceM,
    required this.source,
  });
  int index;
  int tMs;
  double distanceM;
  LapSource source;
}

class CueEvent extends RecorderEvent {
  CueEvent({required this.kind});
  CueKind kind;
}

class FaultEvent extends RecorderEvent {
  FaultEvent({required this.kind, required this.message});
  FaultKind kind;
  String message;
}

@EventChannelApi()
abstract class RecorderEvents {
  RecorderEvent recorderEvents();
}
