import Flutter
import UIKit

// Swift hosts for the Pigeon contract (iOS plan §2.4). Phase 1 stubs: every API answers with a
// safe default and nothing records yet (location + permissions live in LocationSource.swift
// and PermissionsHost.swift). Real implementations replace these one API at a time
// (P3 recorder, P5 place name, P7 strap).

/// Where Swift keeps run data. `path_provider.getApplicationSupportDirectory()` resolves to the
/// same directory on iOS, so Dart's `runs/` and `state/` and Swift's `journals/` share one root.
enum StorageDirs {
  static var support: URL {
    FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
  }

  /// Creates the directories only Swift writes (Dart creates `runs/` and `state/`). Both are
  /// excluded from iCloud backup.
  static func prepare() {
    let fm = FileManager.default
    for name in ["journals", "runs-archive"] {
      var dir = support.appendingPathComponent(name, isDirectory: true)
      do {
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try dir.setResourceValues(values)
      } catch {
        NSLog("RunSupreme: could not prepare \(dir.path): \(error)")
      }
    }
    NSLog("RunSupreme: support dir \(support.path)")
  }
}

final class RecorderApiStub: RecorderApi {
  /// Pre-start GPS readiness (P2). The recorder itself stays a stub until P3.
  var probe: GpsProbe?

  private func notYet() -> StartResult { StartResult(runId: nil, error: .startFailed) }

  func start(mode: RecordMode, spec: SessionSpec?, units: Units, liveContext: LiveContext?, route: FollowRoute?) throws -> StartResult { notYet() }
  func startReplay(mode: RecordMode, spec: SessionSpec?, units: Units, replay: ReplayConfig) throws -> StartResult {
    StartResult(runId: nil, error: .replayUnavailable)
  }
  func resumeRecovered(runId: String) throws -> StartResult { StartResult(runId: nil, error: .noSuchJournal) }
  func pause() throws {}
  func resume() throws {}
  func lap(source: LapSource) throws {}
  func startReps() throws {}
  func stop() throws -> String? { nil }

  func status() throws -> RecorderStatus {
    RecorderStatus(
      state: .idle,
      mode: .free,
      laps: [],
      elapsedMs: 0,
      lapIndex: 0,
      gpsFix: false,
      hrConnected: false,
      phase: .none,
      repIndex: 0,
      phaseRemainingMs: 0,
      journalOk: true
    )
  }

  func recover() throws -> [OrphanJournal] { [] }
  func finalise(runId: String) throws -> String? { nil }
  func discardJournal(runId: String) throws {}
  func discardRun() throws -> Bool { false }
  func setCues(enabled: Bool) throws {}
  func startGpsProbe() throws { DispatchQueue.main.async { self.probe?.start() } }
  func stopGpsProbe() throws { DispatchQueue.main.async { self.probe?.stop() } }
  func setKmSplits(enabled: Bool) throws {}
  func setSpokenSummary(enabled: Bool) throws {}
  func setVoiceCoach(config: VoiceCoachConfig) throws {}
  func setCheckIn(metrics: [String], zoneBottomsBpm: [Double]?) throws {}
  func setCoachSlowdown(slowdown: Double?) throws {}
  func speakRunSummary(distanceM: Double, timeMs: Int64, climbM: Double?, verdict: String?, units: Units, includePace: Bool) throws {}
  func prepareCountdownVoice() throws {}
  func speakCountdownBeat(beat: Int64) throws {}
  func stopCountdownVoice() throws {}
  func setAutoPause(enabled: Bool) throws {}
  func muteTips() throws {}
  func setVolumeKeyLaps(enabled: Bool) throws {}
  func routeSince(fromIndex: Int64) throws -> [Double] { [] }
  func followedRoute() throws -> FollowRoute? { nil }
  func listRunFiles() throws -> [String: String] { [:] }

  func exitDiagnosis(runId: String) throws -> ExitDiagnosis {
    ExitDiagnosis(runId: runId, reason: .other, timestampMs: 0, manufacturer: "Apple")
  }
}

final class StorageApiStub: StorageApi {
  // iCloud backup has no 25 MB cap, so nothing is ever archived (plan §2.4).
  func backupStatus() throws -> BackupStatus {
    BackupStatus(backedUpBytes: 0, budgetBytes: 15 * 1024 * 1024, quotaBytes: 25 * 1024 * 1024, archivedRunCount: 0, overBudget: false)
  }
  func enforceBackupBudget() throws -> [String] { [] }
}

final class PlaceApiStub: PlaceApi {
  func placeName(lat: Double, lon: Double, completion: @escaping (Result<PlaceName?, Error>) -> Void) {
    completion(.success(nil))
  }
}

final class BleApiStub: BleApi {
  func bleScan(completion: @escaping (Result<[BleDevice], Error>) -> Void) { completion(.success([])) }
  func blePair(address: String) throws {}
  func bleForget() throws {}
  func bleStatus() throws -> BleStatus { BleStatus(connected: false, adapterOn: false) }
}

final class HealthApiStub: HealthApi {
  func status(completion: @escaping (Result<HealthStatus, Error>) -> Void) {
    completion(.success(HealthStatus(availability: .unsupported, coreGranted: false, routeGranted: false)))
  }
  func requestAccess(route: Bool, completion: @escaping (Result<Bool, Error>) -> Void) { completion(.success(false)) }
  func openInstall() throws {}
  func writeWorkout(workout: HealthWorkout, completion: @escaping (Result<HealthWriteResult, Error>) -> Void) {
    completion(.success(HealthWriteResult(outcome: .notAvailable, detail: "Apple Health is not supported yet")))
  }
}

/// Holds the event sink while Dart listens. Nothing emits yet (the recorder is a stub), so the
/// stream stays open and quiet; P3 pushes `RecorderEvent`s through `send`.
final class RecorderEventBus: RecorderEventsStreamHandler {
  static let shared = RecorderEventBus()
  private var sink: PigeonEventSink<RecorderEvent>?

  override func onListen(withArguments arguments: Any?, sink: PigeonEventSink<RecorderEvent>) {
    self.sink = sink
  }

  override func onCancel(withArguments arguments: Any?) { sink = nil }

  func send(_ event: RecorderEvent) {
    DispatchQueue.main.async { self.sink?.success(event) }
  }
}

enum PlatformHost {
  static func register(with messenger: FlutterBinaryMessenger) {
    StorageDirs.prepare()
    let recorder = RecorderApiStub()
    recorder.probe = GpsProbe(source: LocationSource()) { RecorderEventBus.shared.send($0) }
    RecorderApiSetup.setUp(binaryMessenger: messenger, api: recorder)
    StorageApiSetup.setUp(binaryMessenger: messenger, api: StorageApiStub())
    PermissionsApiSetup.setUp(binaryMessenger: messenger, api: PermissionsHost())
    PlaceApiSetup.setUp(binaryMessenger: messenger, api: PlaceApiStub())
    BleApiSetup.setUp(binaryMessenger: messenger, api: BleApiStub())
    HealthApiSetup.setUp(binaryMessenger: messenger, api: HealthApiStub())
    RecorderEventsStreamHandler.register(with: messenger, streamHandler: RecorderEventBus.shared)
  }
}
