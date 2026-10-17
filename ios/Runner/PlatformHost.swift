import Flutter
import UIKit

// Swift hosts for the Pigeon contract (iOS plan §2.4). The recorder is RunCore/RecorderApiHost.swift
// (P3); location + permissions live in LocationSource.swift and PermissionsHost.swift. The rest are
// Phase 1 stubs answering safe defaults until their tasks (P5 place name, P7 strap).

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

/// Holds the event sink while Dart listens; `RecorderHost` and the GPS probe push through `send`.
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
    let diagnostics = DiagnosticsLog.shared
    diagnostics.observeSystem()
    LocationSource.trace = { diagnostics.log("location", $0) }
    DiagnosticsChannel.register(with: messenger, log: diagnostics)
    // One location source for the probe and the recorder (P3).
    let source = LocationSource()
    let host = RecorderHost(root: StorageDirs.support, trace: { diagnostics.log("recorder", $0) }) { RecorderEventBus.shared.send($0) }
    let recorder = RecorderApiHost(host: host, source: source, log: diagnostics)
    recorder.probe = GpsProbe(source: source) { RecorderEventBus.shared.send($0) }
    RecorderApiSetup.setUp(binaryMessenger: messenger, api: recorder)
    StorageApiSetup.setUp(binaryMessenger: messenger, api: StorageApiStub())
    PermissionsApiSetup.setUp(binaryMessenger: messenger, api: PermissionsHost())
    PlaceApiSetup.setUp(binaryMessenger: messenger, api: PlaceApiStub())
    BleApiSetup.setUp(binaryMessenger: messenger, api: BleApiStub())
    HealthApiSetup.setUp(binaryMessenger: messenger, api: HealthApiStub())
    RecorderEventsStreamHandler.register(with: messenger, streamHandler: RecorderEventBus.shared)
  }
}
