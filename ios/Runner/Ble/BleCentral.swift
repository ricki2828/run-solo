import Foundation

// The slice of CoreBluetooth the strap client uses, as plain Swift types, so XCTests drive the
// client with a fake central (the simulator has no Bluetooth). `CoreBluetoothCentral` is the one
// real implementation; it holds no policy, only the CB plumbing.

/// One Heart Rate Service (0x180D) advertisement. `id` is `CBPeripheral.identifier.uuidString`:
/// iOS has no MAC address.
struct BleAdvert: Equatable {
  let id: String
  let name: String?
  let rssi: Int
}

protocol BleCentralDelegate: AnyObject {
  /// Power or authorisation changed.
  func centralDidChangeState()
  func central(didDiscover advert: BleAdvert)
  /// The link to `id` is up; the client then calls `beginSetup`.
  func centralDidConnect(id: String)
  /// 0x2A37 notifications are on (the CCCD write succeeded).
  func centralNotificationsReady(id: String)
  /// Service discovery or the notification subscription failed.
  func centralSetupFailed(id: String, what: String)
  /// The link to `id` dropped (a genuine drop, not a cancel the client asked for and replaced).
  func centralDidDisconnect(id: String)
  /// A 0x2A37 value arrived.
  func central(id: String, didReceive data: Data)
}

protocol BleCentral: AnyObject {
  var delegate: BleCentralDelegate? { get set }
  var poweredOn: Bool { get }
  /// False when the runner denied Bluetooth in Settings (or it is restricted).
  var authorized: Bool { get }
  /// A scan for the Heart Rate service. False when it could not start.
  func startScan() -> Bool
  func stopScan()
  /// A connect that never times out: it completes whenever the strap appears. False when the
  /// peripheral is unknown to this device (never scanned, and iOS cannot resolve the identifier).
  func connect(id: String) -> Bool
  /// Drops the link or the pending connect.
  func cancel(id: String)
  /// After `centralDidConnect`: discover 0x180D / 0x2A37 and subscribe.
  func beginSetup(id: String)
}

/// Time for the client: a monotonic millisecond clock and one-shot timers (all on the main queue).
protocol BleScheduling: AnyObject {
  func nowMs() -> Int64
  func after(_ ms: Int64, _ block: @escaping () -> Void) -> Cancelling
}

final class MainScheduler: BleScheduling {
  private let clock: RecorderClock
  init(clock: RecorderClock = .system) { self.clock = clock }

  func nowMs() -> Int64 { clock.monoMs() }

  func after(_ ms: Int64, _ block: @escaping () -> Void) -> Cancelling {
    let item = DispatchWorkItem(block: block)
    DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(Int(ms)), execute: item)
    return WorkHandle(item: item)
  }

  private struct WorkHandle: Cancelling {
    let item: DispatchWorkItem
    func cancel() { item.cancel() }
  }
}

/// The saved strap: survives launches. UserDefaults (declared in the privacy manifest, CA92.1).
protocol BleStrapStore: AnyObject {
  var address: String? { get set }
  var name: String? { get set }
}

final class DefaultsStrapStore: BleStrapStore {
  private let defaults: UserDefaults
  init(defaults: UserDefaults = .standard) { self.defaults = defaults }

  var address: String? {
    get { defaults.string(forKey: "runsupreme.ble.address") }
    set { defaults.set(newValue, forKey: "runsupreme.ble.address") }
  }

  var name: String? {
    get { defaults.string(forKey: "runsupreme.ble.name") }
    set { defaults.set(newValue, forKey: "runsupreme.ble.name") }
  }
}
