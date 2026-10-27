import Foundation

/// Pigeon `BleApi` on iOS: pairing and status over `BleHrClient`. `BleDevice.address` carries the
/// peripheral identifier UUID (iOS has no MAC address).
final class BleApiHost: BleApi {
  let client: BleHrClient

  init(client: BleHrClient) { self.client = client }

  func bleScan(completion: @escaping (Result<[BleDevice], Error>) -> Void) {
    DispatchQueue.main.async {
      self.client.scan { result in
        switch result {
        case .success(let found):
          completion(.success(found.map { BleDevice(address: $0.id, name: $0.name) }))
        case .failure(let error):
          completion(.failure(PigeonError(code: Self.code(error), message: "heart rate strap scan: \(error)", details: nil)))
        }
      }
    }
  }

  func blePair(address: String) throws { DispatchQueue.main.async { self.client.pair(address: address) } }

  func bleForget() throws { DispatchQueue.main.async { self.client.forget() } }

  func bleStatus() throws -> BleStatus {
    // The client is main-queue only; Pigeon calls this on the main queue already.
    BleStatus(
      connected: client.connected, address: client.savedAddress, name: client.deviceName,
      lastHr: client.lastHr.map(Int64.init), adapterOn: client.adapterOn)
  }

  private static func code(_ e: BleHrClient.ScanError) -> String {
    switch e {
    case .budgetSpent: return "scan_budget"
    case .notAuthorized: return "permission"
    case .bluetoothOff: return "bluetooth_off"
    case .couldNotStart: return "scan_failed"
    }
  }
}

/// Feeds strap readings into the live run and reports the link for the status/tick `hr` fields.
final class RecorderStrapBridge: BleHrListener {
  private let host: RecorderHost
  private let lock = NSLock()
  private var _connected = false
  private var _bpm: Int?
  private var _bpmAt: Int64 = 0
  private let nowMs: () -> Int64

  /// A reading older than this is not shown (Android's `HrJoin` window).
  static let freshMs: Int64 = 2_000

  init(host: RecorderHost, nowMs: @escaping () -> Int64 = { RecorderClock.system.monoMs() }) {
    self.host = host
    self.nowMs = nowMs
  }

  /// (link up, latest reading if fresh)
  var snapshot: (connected: Bool, bpm: Int?) {
    lock.lock()
    defer { lock.unlock() }
    return (_connected, _bpm.flatMap { nowMs() - _bpmAt <= Self.freshMs ? $0 : nil })
  }

  func onReading(t: Int64, bpm: Int) {
    lock.lock()
    _bpm = bpm
    _bpmAt = t
    lock.unlock()
    host.feedHr(t: t, bpm: Int32(bpm))
  }

  func onNoContact() {
    lock.lock()
    _bpm = nil
    lock.unlock()
  }

  func onLink(connected: Bool) {
    lock.lock()
    _connected = connected
    if !connected { _bpm = nil }
    lock.unlock()
  }
}
