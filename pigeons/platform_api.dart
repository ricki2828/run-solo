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

/// Run type picked at Start (plan §18.2). Mirrors `RunMode` in `package:run_engine`.
///
/// - `fourByFour`: preset phases, cues, auto-laps, manual LAP overrides.
/// - `laps`: by-feel laps; LAP button, notification LAP and volume keys (opt-in,
///   default on). Schema-1 `free` files map here (plan §18.7).
/// - `free`: no lap input at all — no LAP button, no notification LAP action, no
///   MediaSession; `lap()` is a no-op (`FaultKind.lapIgnored` in debug builds).
/// - `cooper`: schema-2 vocabulary for the Phase-3 12-minute test; until the
///   protocol lands Kotlin records it like `free`. Not offered in the UI yet.
enum RecordMode { fourByFour, laps, free, cooper }

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

  /// The OS killed the process mid-run (read from ApplicationExitInfo on the
  /// next app open); the UI shows the OEM guidance from `exitDiagnosis`.
  osKilledMidRun,

  /// The foreground service could not start after `start` returned a run id;
  /// the run was discarded (no file). Show the message, return to Start.
  startFailed,

  /// A LAP arrived in `free` (or `cooper`) mode and was ignored. Debug builds
  /// only; a UI that shows a LAP control in that mode has a bug.
  lapIgnored,

  /// Android 14 only: volume keys never reach an app's session there, so
  /// volume-key laps are off. Fired at most once per run when volume-key laps
  /// are on; show a one-time note "use the lock-screen LAP".
  volumeKeyUnavailable,
}

/// Typed errors returned by `start` (plan §2). Never a stringly-typed map.
enum StartError {
  noFinePermission,
  approximateOnly,
  locationOff,
  lowStorage,
  notificationsDenied,
  alreadyRunning,

  /// `startReplay` on a release build, or an unknown fixture name.
  replayUnavailable,

  /// `resumeRecovered` for a journal that no longer exists or is unreadable.
  noSuchJournal,

  /// The OS refused the location foreground service (Android 14+ background
  /// start, or the permission was revoked between check and start). Nothing
  /// was recorded; no run file is written.
  fgsNotAllowed,

  /// A brand-new run failed before recording began (storage, journal open);
  /// its empty journal was discarded. Try again.
  startFailed,

  /// `resumeRecovered` failed while reopening the journal. The journal is
  /// untouched and `recover()` will list it again.
  resumeFailed,
}

/// Runtime permissions the setup checklist can request (plan §10). Location is
/// the system prompt only (never a deep link); bluetooth = SCAN + CONNECT on
/// API 31+, nothing to request below.
enum PermissionKind { location, notifications, bluetooth }

/// Why the previous process died, from `ApplicationExitInfo` (API 30+).
enum ExitReason {
  /// No kill recorded for this run (normal stop, or API 29).
  none,
  osKilled,
  lowMemory,
  crash,
  userStop,
  other,
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

/// One recorded lap, for a recreated UI (the "last rep" ghost survives an
/// Activity recreate). `distanceM` is the cumulative run distance at the lap.
class LapSummary {
  LapSummary({
    required this.index,
    required this.tMs,
    required this.activeMs,
    required this.distanceM,
    required this.source,
  });
  int index;

  /// Wall time since Start at the lap marker (pauses and gaps included).
  int tMs;

  /// Duration of the lap that ENDS here, excluding pauses and kill gaps —
  /// what the verdict engine's rep time will be.
  int activeMs;
  double distanceM;
  LapSource source;
}

/// Enough for a recreated UI to redraw mid-run.
class RecorderStatus {
  RecorderStatus({
    required this.state,
    this.runId,
    required this.mode,
    required this.laps,
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

  /// The mode picked at Start (a by-feel 4x4 has `mode == fourByFour` and a
  /// null `preset`).
  RecordMode mode;
  List<LapSummary> laps;
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
    required this.readable,
    required this.newer,
    required this.endedPaused,
    required this.elapsedMs,
  });
  String runId;
  int lastLineAgeMs;
  RecordMode mode;

  /// False when the journal has no decodable header: it can only be discarded
  /// (unless `newer`).
  bool readable;

  /// The journal was written by a newer app (schema or mode this build does not
  /// know). Unreadable here, but NEVER offered for discard: show "update the
  /// app to recover this run"; `discardJournal` refuses it (plan §18.7 W6).
  bool newer;

  /// The run was paused when the process died.
  bool endedPaused;

  /// Run time recorded before the kill (pauses and earlier gaps included).
  int elapsedMs;
}

/// Replay mode (plan §12; debug builds only): a fixture trace fed through the
/// recorder at `speed`x on a virtual clock. `fixture` is `synthetic-4x4`
/// (straight line: 60 s warmup, the preset's reps, 60 s cooldown, HR by phase)
/// or the name of a CSV under the app's Android `assets/replay/`.
class ReplayConfig {
  ReplayConfig({required this.fixture, required this.speed});
  String fixture;
  double speed;
}

/// Everything the setup checklist shows (plan §9, §10).
class PermissionStatus {
  PermissionStatus({
    required this.fineLocation,
    required this.approximateOnly,
    required this.locationEnabled,
    required this.notifications,
    required this.bluetooth,
    required this.batteryUnrestricted,
    required this.gmsAvailable,
  });
  bool fineLocation;

  /// Coarse granted without fine: recording would silently be indoor (W10).
  bool approximateOnly;
  bool locationEnabled;

  /// Granted, or not needed (API < 33).
  bool notifications;

  /// SCAN + CONNECT granted, or not needed (API < 31).
  bool bluetooth;

  /// Not under battery optimisation; false → checklist deep-links to the page.
  bool batteryUnrestricted;

  /// FusedLocationProvider available; false → raw GPS_PROVIDER fallback.
  bool gmsAvailable;
}

class BleStatus {
  BleStatus({
    required this.connected,
    this.address,
    this.name,
    this.lastHr,
    required this.adapterOn,
  });
  bool connected;
  String? address;
  String? name;
  int? lastHr;
  bool adapterOn;
}

/// Result of the OS-kill diagnosis for a run (plan §3, W11).
class ExitDiagnosis {
  ExitDiagnosis({
    required this.runId,
    required this.reason,
    required this.timestampMs,
    this.description,
    required this.manufacturer,
  });
  String runId;
  ExitReason reason;

  /// Wall-clock epoch ms of the kill, 0 when none.
  int timestampMs;

  /// Raw `ApplicationExitInfo.description`, for the diagnostics screen.
  String? description;

  /// `Build.MANUFACTURER` lower-cased, so the UI picks per-OEM guidance.
  String manufacturer;
}

class BleDevice {
  BleDevice({required this.address, this.name});
  String address;
  String? name;
}

/// What the static Auto Backup rules would back up right now (plan §4, W3):
/// `databases/runsolo.db` + `files/runs/` run files + sidecars. `files/state/`
/// is a few KB and not counted. Over the 25 MB `quotaBytes` Android backs up
/// nothing, so the app keeps the set under `budgetBytes` (15 MB) by archiving.
class BackupStatus {
  BackupStatus({
    required this.backedUpBytes,
    required this.budgetBytes,
    required this.quotaBytes,
    required this.archivedRunCount,
    required this.overBudget,
  });
  int backedUpBytes;
  int budgetBytes;
  int quotaBytes;

  /// Runs already in `files/runs-archive/` (on device, indexed, not backed up).
  int archivedRunCount;
  bool overBudget;
}

@HostApi()
abstract class RecorderApi {
  /// Idempotent: a second call while recording returns the running id. Must be
  /// called while the Activity is visible (the FGS is started from it, B2).
  StartResult start(RecordMode mode, Preset? preset, Units units);

  /// Debug builds only: like `start`, fed from a fixture instead of GPS/BLE.
  StartResult startReplay(
    RecordMode mode,
    Preset? preset,
    Units units,
    ReplayConfig replay,
  );

  /// Continue an orphaned journal after the user confirms (plan §3): writes the
  /// `gap` line, rebuilds the preset phase from the journal, restarts the FGS.
  /// Idempotent like `start`.
  StartResult resumeRecovered(String runId);
  void pause();
  void resume();
  void lap(LapSource source);

  /// The "Start 4x4" action: ends the untimed warm-up and starts rep 1 (same
  /// effect and journal line as a first `lap(button)`); a no-op anywhere else,
  /// so a manual LAP mid-rep can never be confused with starting.
  void startReps();

  /// Finalises in Kotlin (journal -> tmp -> fsync -> rename -> delete journal). No-op when idle.
  String? stop();
  RecorderStatus status();

  /// Called on app open: journals without a finalised file, newest first. Never
  /// includes the run that is being recorded.
  List<OrphanJournal> recover();

  /// Finalise an orphaned journal without resuming it. Returns the run file
  /// path relative to the app's files dir, or null when nothing was there.
  String? finalise(String runId);

  /// Delete an unreadable orphan (`readable == false`). Never touches a run file.
  void discardJournal(String runId);
  void setCues(bool enabled);

  /// Run files on disk (`runs/` + `runs-archive/`) as `runId -> relative path`,
  /// for the Dart Reconciler. Journals and sidecars are not listed.
  Map<String, String> listRunFiles();

  /// Was the previous process killed by the OS while `runId` was recording?
  ExitDiagnosis exitDiagnosis(String runId);
}

/// Backup budget (plan §4). Journals live in `files/journals/`, run files in
/// `files/runs/`, overflow in `files/runs-archive/`; the rules files exclude
/// journals, the archive and the SQLite `-wal`/`-shm`/`-journal` side files.
@HostApi()
abstract class StorageApi {
  BackupStatus backupStatus();

  /// Moves the oldest run files (with their sidecars) into `runs-archive/`
  /// until the backed-up set fits the budget; returns the run ids moved. Call
  /// after each finalise/import, then run the Reconciler (rows get `repath`).
  /// Non-empty → show "export to keep older runs safe". Never touches the run
  /// being recorded, never deletes anything.
  List<String> enforceBackupBudget();
}

@HostApi()
abstract class PermissionsApi {
  PermissionStatus permissionStatus();

  /// Shows the system prompt (or the enable-location dialog for `location` when
  /// the setting is off). Resolves when the user answers; true = granted.
  @async
  bool requestPermission(PermissionKind kind);

  /// The only Settings deep link allowed (plan §10): the app's battery page.
  /// The setup checklist's battery step opens this and re-reads
  /// `batteryUnrestricted`; the direct REQUEST_IGNORE_BATTERY_OPTIMIZATIONS
  /// dialog is not used (Play flags the declaration for this app type).
  void openBatterySettings();
  void openAppSettings();

  /// `FLAG_KEEP_SCREEN_ON` on the Activity window (design brief: screen stays
  /// on while recording, user setting). Cleared automatically when the
  /// Activity is recreated, so call it again from the recording screen.
  void setKeepScreenOn(bool enabled);
}

@HostApi()
abstract class BleApi {
  /// Scan once for Heart Rate Profile (0x180D) devices to pair (≤ 10 s).
  @async
  List<BleDevice> bleScan();

  /// Saves the address and connects; reconnects use autoConnect, never a rescan.
  void blePair(String address);
  void bleForget();
  BleStatus bleStatus();
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
    required this.phase,
    required this.repIndex,
    required this.phaseRemainingMs,
  });

  /// Wall time since Start, pauses included.
  int elapsedMs;
  int lapElapsedMs;

  /// Distance since the last lap marker (`totalDistanceM` is cumulative).
  double lapDistanceM;

  /// Rolling 15 s "live" pace; differs from the verdict's trimmed pace.
  double? lapPaceLiveSecPerKm;
  double totalDistanceM;
  int? hr;
  double? gpsAccuracyM;
  RecorderState state;
  Phase phase;
  int repIndex;

  /// Active-time countdown of the current timed phase (0 when untimed).
  int phaseRemainingMs;
}

class LapEvent extends RecorderEvent {
  LapEvent({
    required this.index,
    required this.tMs,
    required this.activeMs,
    required this.distanceM,
    required this.source,
  });
  int index;
  int tMs;

  /// Duration of the lap that ends here, excluding pauses and kill gaps.
  int activeMs;
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

/// Recorder state transitions (start, pause, resume, stop, finalised), so a UI
/// that missed a tick still redraws; `status()` remains the source of truth.
class StateEvent extends RecorderEvent {
  StateEvent({required this.state, this.runId, required this.phase});
  RecorderState state;
  String? runId;
  Phase phase;
}

/// Preset phase change (warmup -> work 1 -> recovery 1 -> ... -> cooldown).
class PhaseEvent extends RecorderEvent {
  PhaseEvent({
    required this.phase,
    required this.repIndex,
    required this.phaseDurationMs,
  });
  Phase phase;
  int repIndex;

  /// 0 for untimed phases (warmup, cooldown).
  int phaseDurationMs;
}

@EventChannelApi()
abstract class RecorderEvents {
  RecorderEvent recorderEvents();
}
