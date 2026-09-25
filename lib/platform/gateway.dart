/// Dart-side seams over the Pigeon contract (plan §2). Screens depend on
/// these, never on the generated classes directly, so a fake implementation
/// can drive every screen state and the widget tests never touch a
/// MethodChannel. Semantics mirror `RecordingSession.kt` exactly:
///
/// * `TickEvent.elapsedMs` runs through pauses; `RecorderStatus.phaseRemainingMs`
///   counts active time only (a pause freezes the countdown). Ticks keep
///   arriving while paused with `state == paused`.
/// * `LapEvent.distanceM` is the run's cumulative distance at the lap, so lap
///   distance is the delta from the previous lap.
/// * `repIndex` is 1-based in work / recovery; the last rep goes straight to
///   cool-down (N reps, N − 1 recoveries).
/// * `hr == null` means no strap or no contact, never 0.
library;

import 'platform_api.g.dart';

export 'platform_api.g.dart';

/// What the setup checklist needs (plan §10), mapped from `PermissionStatus`.
class PermissionSnapshot {
  const PermissionSnapshot({
    this.fineLocation = false,
    this.coarseOnly = false,
    this.locationServicesOn = true,
    this.notifications = false,
    this.bluetooth = false,
    this.batteryUnrestricted = false,
    this.gmsAvailable = true,
  });

  factory PermissionSnapshot.fromStatus(PermissionStatus s) =>
      PermissionSnapshot(
        fineLocation: s.fineLocation,
        coarseOnly: s.approximateOnly,
        locationServicesOn: s.locationEnabled,
        notifications: s.notifications,
        bluetooth: s.bluetooth,
        batteryUnrestricted: s.batteryUnrestricted,
        gmsAvailable: s.gmsAvailable,
      );

  final bool fineLocation;
  final bool coarseOnly;
  final bool locationServicesOn;
  final bool notifications;
  final bool bluetooth;
  final bool batteryUnrestricted;
  final bool gmsAvailable;

  /// Recording can start (plan §10: fine location + services on). Notifications
  /// denied and battery-restricted are flagged red but do not block.
  bool get canRecord => fineLocation && !coarseOnly && locationServicesOn;

  /// Every row green, so Home collapses the checklist to one line.
  bool get allGood =>
      canRecord && notifications && bluetooth && batteryUnrestricted;

  PermissionSnapshot copyWith({
    bool? fineLocation,
    bool? coarseOnly,
    bool? locationServicesOn,
    bool? notifications,
    bool? bluetooth,
    bool? batteryUnrestricted,
    bool? gmsAvailable,
  }) => PermissionSnapshot(
    fineLocation: fineLocation ?? this.fineLocation,
    coarseOnly: coarseOnly ?? this.coarseOnly,
    locationServicesOn: locationServicesOn ?? this.locationServicesOn,
    notifications: notifications ?? this.notifications,
    bluetooth: bluetooth ?? this.bluetooth,
    batteryUnrestricted: batteryUnrestricted ?? this.batteryUnrestricted,
    gmsAvailable: gmsAvailable ?? this.gmsAvailable,
  );
}

abstract class RecorderGateway {
  /// Must be called while the Activity is visible (FGS start, B2).
  Future<StartResult> start(RecordMode mode, Preset? preset, Units units);
  Future<void> pause();
  Future<void> resume();
  Future<void> lap(LapSource source);

  /// 4x4 "Start 4x4" button: ends the untimed warm-up and begins rep 1. A
  /// no-op outside warm-up, so a LAP mid-rep is never taken as starting.
  Future<void> startReps();

  /// Finalises in Kotlin before returning the run id; null when idle.
  Future<String?> stop();
  Future<RecorderStatus> status();

  /// Orphaned journals, newest first; never the live run.
  Future<List<OrphanJournal>> recover();

  /// Continue an orphan (writes the gap line, rebuilds the phase). Activity
  /// must be visible, like `start`.
  Future<StartResult> resumeRecovered(String runId);

  /// Finalise an orphan without resuming; returns the run file path relative
  /// to the files dir, or null when nothing was there.
  Future<String?> finalise(String runId);

  /// Delete an unreadable orphan (`readable == false`).
  Future<void> discardJournal(String runId);
  Future<void> setCues(bool enabled);

  /// Saved volume-key lap choice; native applies it from the next start or
  /// resume (never mid-run) and never in Free. Start sends it before every
  /// start so the Settings/Start toggle is authoritative.
  Future<void> setVolumeKeyLaps(bool enabled);

  /// Broadcast; ≤ 2 Hz ticks plus lap / phase / state / cue / fault events.
  Stream<RecorderEvent> get events;
}

abstract class BleGateway {
  Future<List<BleDevice>> scan();
  Future<void> pair(BleDevice device);
  Future<void> forget();

  /// Saved strap + live connection, with or without a run.
  Future<BleStatus> status();
}

/// Auto Backup budget (plan §4, native #9 contract): after each finalise
/// and import the app asks Kotlin to move the oldest runs (file + sidecar)
/// to `files/runs-archive/` until the backed-up set is under budget; the
/// store scans both directories, so nothing disappears from History.
abstract class StorageGateway {
  Future<BackupStatus> backupStatus();

  /// Run ids moved to the archive this call; empty when under budget.
  Future<List<String>> enforceBackupBudget();
}

abstract class PermissionsGateway {
  Future<PermissionSnapshot> status();

  /// System prompt; true = granted (fine, for location). Re-read [status]
  /// after for the full snapshot.
  Future<bool> request(PermissionKind kind);

  /// Battery-optimisation settings page (fallback when the exemption dialog
  /// is unavailable).
  Future<void> openBatterySettings();

  /// Battery-optimisation shortcut (Settings row + checklist): opens the
  /// system battery page and re-reads status. The direct exemption dialog
  /// was dropped (Play-restricted, 24-Sep review). True when exempt after.
  Future<bool> requestBatteryExemption();

  /// App info page, for a "don't ask again" denial of notifications / BLE.
  Future<void> openAppSettings();

  /// FLAG_KEEP_SCREEN_ON on the Activity window; resets on recreate, so the
  /// record screen re-applies it on init and state changes.
  Future<void> setKeepScreenOn(bool enabled);

  /// False on Android 14 (API 34): the system never routes volume keys to an
  /// app's session there, so native registers none and fires
  /// `volumeKeyUnavailable` once per run. Start and Settings disable the
  /// volume-key toggle with a one-line reason.
  Future<bool> volumeKeyLapsSupported();
}
