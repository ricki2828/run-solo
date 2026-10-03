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
  /// Must be called while the Activity is visible (FGS start, B2). [spec]:
  /// required for intervals and cooper, the fartlek or bronco spec or null for laps,
  /// null for free (CONTRACT.md I1). [liveContext]: the live compare's
  /// history (Phase 4 §3.2), or null for none. [route]: a route to follow
  /// (Follow a route; Free, Trail and Goal runs), or null for none.
  Future<StartResult> start(
    RecordMode mode,
    SessionSpec? spec,
    Units units, {
    LiveContext? liveContext,
    FollowRoute? route,
  });
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

  /// Throw the live run away (DISCARD on the finish screen): no run file, the
  /// journal deleted, state back to idle. False when no run is on.
  Future<bool> discard();
  Future<void> setCues(bool enabled);

  /// Pre-start GPS readiness: [GpsProbeEvent]s on [events] about 1 Hz until
  /// [stopGpsProbe] (or any start). Call stop when the screen closes.
  Future<void> startGpsProbe();
  Future<void> stopGpsProbe();

  /// Voice → "Km splits": a Free run says each km. Persisted natively.
  Future<void> setKmSplits(bool enabled);

  /// Voice → "Spoken summary": a line at the start and end of a run.
  /// Persisted natively.
  Future<void> setSpokenSummary(bool enabled);

  /// The end-of-run line (see the Pigeon `speakRunSummary`); [verdict] is the
  /// result screen's words, null when none is computed yet.
  Future<void> speakRunSummary({
    required double distanceM,
    required int timeMs,
    double? climbM,
    String? verdict,
    required Units units,
    bool includePace = true,
  });

  /// Settings → Recording → "Auto-pause": the recorder pauses itself when the
  /// runner stops and resumes when they move. Persisted natively; read at
  /// start and live.
  Future<void> setAutoPause(bool enabled);

  /// "Mute tips" for this run (LV2): no compare speech, no nudges, no card.
  /// Native answers with a state event; `status().tipsMuted` turns true.
  Future<void> muteTips();

  /// Saved volume-key lap choice for Laps runs (4x4 and Free never hook the
  /// volume keys). Native applies it from the next start or resume, never
  /// mid-run; Start sends it before every Laps start.
  Future<void> setVolumeKeyLaps(bool enabled);

  /// The live map's route from point [fromIndex] on, flat `[lat, lon, ...]`:
  /// the catch-up after a recreated screen or a gap in [RoutePointsEvent]s.
  /// Read-only; recording never depends on it. Empty when idle.
  Future<List<double>> routeSince(int fromIndex);

  /// The route the live run follows (as Start gave it, or as the journal had
  /// it after a restore); null when idle or following none. Read-only.
  Future<FollowRoute?> followedRoute();

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

/// What the geocoder said about a start point: the street (no house number)
/// and the area ("Albert Park"). Either may be null.
class PlaceLookup {
  const PlaceLookup({this.street, this.area});
  final String? street;
  final String? area;
}

/// A street and area name for a run's start point from the phone's own
/// geocoder. The app sends nothing itself.
abstract class PlaceGateway {
  /// The street and area, or null: no geocoder, offline, or no answer. Never
  /// throws and never returns a coordinate.
  Future<PlaceLookup?> placeName(double lat, double lon);
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
