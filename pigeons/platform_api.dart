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

/// Run type picked at Start (plan §18.2, Phase 3 §3.8). Mirrors `RunMode` in
/// `package:run_engine`.
///
/// - `intervals`: the phases follow a `SessionSpec` (cues, auto-laps, manual LAP
///   overrides). Schema <= 2 `fourByFour` files map here.
/// - `laps`: by-feel laps; LAP button, notification LAP and volume keys (opt-in,
///   default on). Schema-1 `free` files map here (plan §18.7). A fartlek is
///   `laps` with the steps-empty fartlek spec.
/// - `free`: no lap input at all — no LAP button, no notification LAP action, no
///   MediaSession; `lap()` is a no-op (`FaultKind.lapIgnored` in debug builds).
/// - `cooper`: the 12-minute test with the Cooper spec: no LAP, `startReps`
///   starts the 12:00, projection cues. Not offered in the UI yet.
enum RecordMode { intervals, laps, free, cooper }

enum Units { km, mi }

enum RecorderState { idle, recording, paused, finalising }

/// Phase of an intervals run; `none` in the other modes.
enum Phase { none, warmup, work, recovery, cooldown }

enum LapSource { button, notification, volumeKey, auto }

/// `distanceToGo`, `lastRep`, `minuteMark`, `countdown` and `projection` are
/// Phase 3 cues (I2); I1 never emits them.
enum CueKind {
  halfway,
  thirtySeconds,
  phaseEnd,
  start,
  stop,
  distanceToGo,
  lastRep,
  minuteMark,
  countdown,
  projection,
}

enum StepKind { work, recovery }

/// `time`: value in seconds; `distance`: metres; `equalToPreviousWork`: value
/// 0, lasts as long as the work step before it took (Yasso, pyramids).
enum TargetKind { time, distance, equalToPreviousWork }

/// Work steps are always `run`; recoveries `jog`, `walk` or `stand`.
enum RecoveryStyle { run, jog, walk, stand }

enum CueProfile { standard, short, cooper }

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

  /// The session fails validation or does not fit the mode (intervals and
  /// cooper need their session, laps takes only the fartlek, free none).
  /// Nothing started.
  unsupportedSession,
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

/// One expanded step (named `SessionStep`: a generated `Step` would clash
/// with Flutter material's `Step`). `repIndex` is 1-based; a recovery carries
/// the rep number of the work step before it (run-file JSON key `rep`).
class SessionStep {
  SessionStep({
    required this.kind,
    required this.target,
    required this.value,
    required this.style,
    required this.repIndex,
  });
  StepKind kind;
  TargetKind target;
  int value;
  RecoveryStyle style;
  int repIndex;
}

/// The expanded session (Phase 3 §3.3): Dart expands presets and custom
/// templates, Kotlin validates, journals and runs the flat step list. Written
/// to the run file as `session` (hrBand as `[low, high]`).
class SessionSpec {
  SessionSpec({
    required this.templateId,
    required this.templateVersion,
    required this.name,
    this.warmupSeconds,
    this.cooldownSeconds,
    required this.lapLockout,
    this.autoStop,
    required this.cueProfile,
    this.hrBandLow,
    this.hrBandHigh,
    required this.steps,
  });
  String templateId;
  int templateVersion;
  String name;

  /// null = open (ends on the first LAP / `startReps`); 0 = none, step 1
  /// starts at `start()` (parkrun); otherwise fixed seconds (300..1200).
  int? warmupSeconds;

  /// null = open (runs until Stop); int = fixed seconds.
  int? cooldownSeconds;
  bool lapLockout;

  /// The recording stops itself when the last timed part ends (the last step,
  /// or a fixed cool-down): parkrun stops at 5.00 km. Null = false.
  bool? autoStop;
  CueProfile cueProfile;
  double? hrBandLow;
  double? hrBandHigh;
  List<SessionStep> steps;
}

/// Which kind of board a run races live (Phase 4 §3.2). `distanceInTime`
/// (Phase 4 §G) ranks the most distance in a fixed time (`be:t1800`, a
/// custom time goal's `goal:t2700`); its entries carry `cooperMinuteM`.
enum LiveBoardKind { distance, intervals, cooper, distanceInTime }

/// One prior run on a live board. Exactly one of the three series is set,
/// by the board's kind: `fromStartSplitsMs` (distance: cumulative ms from
/// the Start press at each whole km, WARN-1), `liveRepPacesSecPerKm`
/// (intervals: untrimmed lap distance / lap time per work rep, null for an
/// unclean rep, BLOCK-2), `cooperMinuteM` (Cooper and distance-in-time:
/// cumulative metres at each whole minute from the Start).
class LiveEntry {
  LiveEntry({
    required this.runId,
    required this.dateMs,
    this.fromStartSplitsMs,
    this.liveRepPacesSecPerKm,
    this.cooperMinuteM,
    required this.finalMetric,
  });
  String runId;

  /// Run start, epoch millis.
  int dateMs;
  List<int>? fromStartSplitsMs;
  List<double?>? liveRepPacesSecPerKm;
  List<double>? cooperMinuteM;

  /// The board's metric for the whole run (finish ms, mean rep pace s/km,
  /// or raw Cooper VO2), for "your #k of n" at the end.
  double finalMetric;
}

/// A board the live compare ranks against: at most 20 entries (top 10 +
/// last 10, deduped). The app only sends a board with 2 or more entries.
class LiveBoard {
  LiveBoard({
    required this.key,
    required this.label,
    required this.kind,
    this.targetM,
    required this.entries,
  });

  /// The comparison key (`be:5000`, an intervals key, `cooper`, a course).
  String key;

  /// Spoken and shown name ("5K", "8 × 400 m"); the app injects any event
  /// name, the engine never writes it.
  String label;
  LiveBoardKind kind;

  /// Distance boards: the board's distance (5000 for a 5K board).
  double? targetM;
  List<LiveEntry> entries;
}

/// Phase 4 §3.4: a target to race (a predicted time or a recent PB). PD2
/// fills it; even splits over [distanceM].
class LiveTarget {
  LiveTarget({
    required this.distanceM,
    required this.targetMs,
    required this.predicted,
  });
  double distanceM;
  int targetMs;

  /// True = "predicted" (an estimate), false = "your PB".
  bool predicted;
}

/// In-run coaching nudges (Phase 4 §3.5, CR1): the engine's thresholds
/// (`NudgePlanSpec.toJson`, key for key); native compares live figures
/// against them. A null rule is off. `version` 0 = the LC1 stub (no rules).
class NudgePlan {
  NudgePlan({
    required this.version,
    this.fastStart,
    this.repFade,
    this.hrDrift,
    this.blocked,
  });
  int version;
  FastStartRule? fastStart;
  RepFadeRule? repFade;
  HrDriftRule? hrDrift;

  /// "rule:index" said on the previous run of this board (WARN-5).
  List<String>? blocked;
}

/// Fire at km 1 when the live km-1 split (ms from Start) is under [km1MaxMs].
class FastStartRule {
  FastStartRule({required this.km1MaxMs, required this.text});
  int km1MaxMs;
  String text;
}

/// At the end of rep r ≥ 3: fire when live rep r pace − rep 1 pace (s/km) is
/// over `maxDropSecPerKm[r − 1]` (null = off for that rep).
class RepFadeRule {
  RepFadeRule({required this.maxDropSecPerKm, required this.text});
  List<double?> maxDropSecPerKm;
  String text;
}

/// HR up for this pace, like with like (#56 review P2): `kmSamples[k − 1]` =
/// the recent board runs' [pace s/km, mean HR] pairs at km k. At km
/// k ≥ [firstKm]: of the runs whose pace was within [paceBand] of the live km
/// pace, with at least [minSimilar] of them, fire when the live km HR is at
/// least their median + [bpmOver].
class HrDriftRule {
  HrDriftRule({
    required this.kmSamples,
    required this.bpmOver,
    required this.paceBand,
    required this.firstKm,
    required this.minSimilar,
    required this.text,
  });
  List<List<List<double>>> kmSamples;
  double bpmOver;
  double paceBand;
  int firstKm;
  int minSimilar;
  String text;
}

/// Everything the live "you vs you" needs, built by the app at Start within
/// 150 ms or not at all (WARN-3), journaled as the `live_context` line and
/// rebuilt from it on restore (BLOCK-1). Kotlin never reads history.
class LiveContext {
  LiveContext({
    required this.boards,
    this.target,
    this.nudges,
    this.cooperCurve,
    this.cooperHistory,
    required this.coachingMuted,
    required this.builtAtMs,
    required this.engineVersion,
  });

  /// At most 3.
  List<LiveBoard> boards;
  LiveTarget? target;
  NudgePlan? nudges;

  /// Cooper: cumulative fade fractions F(1)..F(12), F(12) = 1 (§3.3).
  List<double>? cooperCurve;

  /// Cooper: past raw VO2 estimates, oldest first (the last is the previous
  /// test, for "up 2 on last time").
  List<double>? cooperHistory;
  bool coachingMuted;

  /// Epoch millis when the app built it.
  int builtAtMs;
  int engineVersion;
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
    this.spec,
    this.stepIndex,
    this.stepRemainingMs,
    this.stepRemainingM,
    required this.journalOk,
  });
  RecorderState state;
  String? runId;

  /// The mode picked at Start.
  RecordMode mode;
  List<LapSummary> laps;
  int elapsedMs;
  int lapIndex;
  bool gpsFix;
  bool hrConnected;
  Phase phase;
  int repIndex;
  int phaseRemainingMs;
  SessionSpec? spec;

  /// 0-based index into `spec.steps` during work/recovery; null in warm-up,
  /// cool-down and unstructured runs.
  int? stepIndex;
  int? stepRemainingMs;

  /// Metres left in a distance step (I2; null until then).
  double? stepRemainingM;
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
/// (straight line: 60 s warmup, the spec's steps, 60 s cooldown, HR by phase)
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
  ///
  /// `spec`: required for `intervals` and `cooper`, the fartlek spec or null
  /// for `laps`, null for `free`; anything else is `unsupportedSession`.
  /// `liveContext`: the history the live compare needs (Phase 4 §3.2; Kotlin
  /// does not read history), journaled as the `live_context` line after the
  /// header; null = no compare, no overlay, no nudges, nothing said. The
  /// previous Cooper VO2 for "up 2 on last time" is the last
  /// `cooperHistory` entry.
  StartResult start(
    RecordMode mode,
    SessionSpec? spec,
    Units units,
    LiveContext? liveContext,
  );

  /// Debug builds only: like `start`, fed from a fixture instead of GPS/BLE.
  StartResult startReplay(
    RecordMode mode,
    SessionSpec? spec,
    Units units,
    ReplayConfig replay,
  );

  /// Continue an orphaned journal after the user confirms (plan §3): writes the
  /// `gap` line, rebuilds the step phase from the journal, restarts the FGS.
  /// Idempotent like `start`.
  StartResult resumeRecovered(String runId);
  void pause();
  void resume();
  void lap(LapSource source);

  /// The "Start reps" action: ends the untimed warm-up and starts rep 1 (same
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

  /// Pre-start location readiness (the Start screen): fixes with the
  /// recording's provider settings, a [GpsProbeEvent] about once a second.
  /// Idempotent. Stopped by [stopGpsProbe], by any start, and when the app
  /// leaves the foreground; foreground only, no service.
  void startGpsProbe();
  void stopGpsProbe();

  /// Settings → Voice → "Km splits" (default on): a Free run says each km
  /// ("3 k, 15 minutes 20, pace 5:07."). Persisted natively; applies to a run
  /// in progress too.
  void setKmSplits(bool enabled);

  /// The user's volume-key LAP setting for Laps runs, persisted natively (the
  /// recorder reads it at start). Takes effect from the next run or resume,
  /// not the live one. Unset means on. Intervals, Free and Cooper never use
  /// volume keys, whatever this says. A no-op in effect where
  /// `PermissionsApi.volumeKeyLapsSupported()` is false.
  void setVolumeKeyLaps(bool enabled);

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

  /// Whether volume keys can land laps on this device. False on Android 14
  /// (API 34), where keys never reach an app's session: hide the volume-key
  /// LAP setting there and point at the lock-screen LAP instead.
  bool volumeKeyLapsSupported();
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
    this.stepIndex,
    this.stepRemainingMs,
    this.stepRemainingM,
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

  /// As `RecorderStatus`: the 0-based step (null in warm-up/cool-down), the
  /// time left in a time step, the metres left in a distance step (whose
  /// `phaseRemainingMs` is 0).
  int? stepIndex;
  int? stepRemainingMs;
  double? stepRemainingM;
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

/// A manual lap (button, notification, volume key, "Start reps") the core
/// accepted, sent at the press. The [LapEvent] with the same [index] follows
/// on the next tick (up to 1 s later, so its distance is interpolated at the
/// press); until then the UI shows the new lap from this. [endedPhase] and
/// [endedRepIndex] are the phase the lap closes, so the lap's pace is
/// attributed by the lap itself, never by arrival order. [nextPhase] is set
/// when the lap re-aligns a structured session (its [PhaseEvent] also
/// follows the [LapEvent]).
class LapPendingEvent extends RecorderEvent {
  LapPendingEvent({
    required this.index,
    required this.tMs,
    required this.activeMs,
    required this.source,
    required this.endedPhase,
    required this.endedRepIndex,
    this.nextPhase,
    this.nextRepIndex,
    this.nextPhaseDurationMs,
  });
  int index;
  int tMs;
  int activeMs;
  LapSource source;
  Phase endedPhase;
  int endedRepIndex;
  Phase? nextPhase;
  int? nextRepIndex;

  /// 0 for untimed phases, like [PhaseEvent.phaseDurationMs].
  int? nextPhaseDurationMs;
}

class CueEvent extends RecorderEvent {
  CueEvent({required this.kind, this.value});
  CueKind kind;

  /// `projection`: the projected Cooper distance in metres, or a distance
  /// step's projected finish in ms; `minuteMark`: the minute. Null otherwise.
  double? value;
}

/// Pre-start GPS readiness, about 1 Hz while the probe runs. The "ready"
/// threshold is the screen's; native sends the raw values.
class GpsProbeEvent extends RecorderEvent {
  GpsProbeEvent({
    required this.fix,
    this.lat,
    this.lon,
    this.accuracyM,
    this.fixAgeMs,
  });

  /// A location arrived within the last 5 s.
  bool fix;

  /// Where the runner is now (with a fresh fix only): the app picks the event
  /// course by its nearest known start. In memory only; nothing is stored
  /// until the run records.
  double? lat;
  double? lon;

  /// That fix's accuracy (m); null without a fresh fix.
  double? accuracyM;

  /// How long ago the last fix arrived; null if none yet.
  int? fixAgeMs;
}

/// A live "you vs you" compare fired (Phase 4 §3.2, LV1), for the overlay card.
/// Sent whether or not tips are muted; [text] is the spoken phrase.
class CompareEvent extends RecorderEvent {
  CompareEvent({
    required this.boardKey,
    required this.boardLabel,
    required this.kind,
    required this.index,
    required this.rank,
    required this.of,
    this.deltaMs,
    this.deltaSecPerKm,
    this.deltaVo2,
    this.value,
    required this.text,
    required this.overlay,
  });
  String boardKey;
  String boardLabel;

  /// `distance`, `intervals`, `cooper` or `target`.
  String kind;

  /// The km, rep or minute.
  int index;

  /// This run's place among itself and [of] − 1 compared entries.
  int rank;
  int of;

  /// distance / target: live − best entry (or the target's split); negative = ahead.
  int? deltaMs;

  /// intervals: live mean rep pace − the best prior's, s/km; negative = faster.
  double? deltaSecPerKm;

  /// cooper: projected VO2 − the best past test.
  double? deltaVo2;

  /// cooper: the projected VO2; target: the target time in ms.
  double? value;
  String text;

  /// False when a recovery is under 20 s: voice only, no card.
  bool overlay;
}

/// A GOAL run reached its goal (§G): the step closed on its distance or time;
/// the recording goes on as an open cool-down. The engine's goal result from
/// the run file is the one of record; this is the live moment (the goal card).
class GoalEvent extends RecorderEvent {
  GoalEvent({
    required this.distanceGoal,
    required this.goalValue,
    required this.timeMs,
    required this.distanceM,
    required this.newBest,
    required this.interrupted,
    required this.text,
  });

  /// True for a distance goal, false for a time goal.
  bool distanceGoal;

  /// The goal: metres or seconds.
  int goalValue;

  /// Moving time at the goal point (pauses and gaps out).
  int timeMs;
  double distanceM;

  /// Beats every entry on the goal's board (never when [interrupted]).
  bool newBest;

  /// A kill gap fell before the goal (WARN-G2): the result may be off.
  bool interrupted;

  /// What was said.
  String text;
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

/// Phase change (warmup -> work 1 -> recovery 1 -> ... -> cooldown).
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
