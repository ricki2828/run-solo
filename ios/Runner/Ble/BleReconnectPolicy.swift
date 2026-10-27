import Foundation

/// Connect and reconnect decisions for the paired strap. Swift twin of the Kotlin
/// `BleReconnectPolicy` (same states, backoff, scan budget and matching rules; the unit tests are
/// ported from `BleTest.kt`). The client asks this object what to do on every link and scan event
/// and does exactly that.
///
/// Scan-first: a WHOOP in "Broadcast Heart Rate" is not bonded and advertises from a rotating
/// address, so the identifier saved at pairing can go stale (CoreBluetooth derives the peripheral
/// UUID from the address on the device). Apart from pairing, the strap is only connected directly
/// to an identifier a scan has just seen:
///  - pairing connects to the identifier its scan just returned (`pair`);
///  - every other connect starts with a hunt: one long scan for the Heart Rate service plus a
///    pending connect to the saved identifier (iOS: a `connect` that never times out, the
///    equivalent of Android's autoConnect). The first scan result that is the saved strap is
///    connected, and the saved identifier and name are re-pointed;
///  - a connect with no first measurement in time, a dropped link or a failed setup go back to a
///    hunt after a backoff (0.5 s, 1 s, 2 s ... capped at `maxDelayMs`, reset after a link that
///    stayed up `stableMs`).
///
/// Matching never takes another runner's strap: the saved identifier, else the saved name
/// (case-insensitive). Nothing looser.
final class BleReconnectPolicy {
  enum Action: Equatable {
    case nothing
    /// Stop any scan, drop the current link, then connect directly to `address` after `delayMs`.
    case connect(address: String, delayMs: Int64)
    /// Drop the current link, then after `delayMs` scan for up to `scanMs` (results to
    /// `onScanResult`, its end to `onScanEnded`) and start a pending connect to `passiveAddress`.
    case hunt(delayMs: Int64, scanMs: Int64, passiveAddress: String, lowLatency: Bool)
  }

  enum LinkState { case idle, hunting, connecting, connected }

  struct Candidate: Equatable {
    let address: String
    let name: String?
    var rssi: Int = 0
  }

  enum Match { case address, name }

  static let scanStartsPerWindow = 4
  static let scanWindowMs: Int64 = 30_000
  static let huntScanMs: Int64 = 5 * 60_000
  static let fastHunts = 2
  static let fastScanMs: Int64 = 60_000

  private(set) var savedAddress: String?
  private(set) var savedName: String?
  private(set) var attempts = 0
  private(set) var state: LinkState = .idle
  private(set) var lastMatch: Match?

  private let initialDelayMs: Int64
  private let maxDelayMs: Int64
  private let stableMs: Int64
  private var scanStarts: [Int64] = []  // may hold one planned (future) hunt start
  private var nextDelay: Int64
  private var connectedAt: Int64?
  private var seen: [Candidate] = []  // this hunt's HR peripherals, first-seen order, unique by address
  private var huntsThisEpisode = 0

  init(address: String?, name: String? = nil, initialDelayMs: Int64 = 500, maxDelayMs: Int64 = 8_000, stableMs: Int64 = 10_000) {
    savedAddress = address
    savedName = name
    self.initialDelayMs = initialDelayMs
    self.maxDelayMs = maxDelayMs
    self.stableMs = stableMs
    nextDelay = initialDelayMs
  }

  /// `blePair`: remember the strap and connect directly (a scan just saw this identifier).
  func pair(address: String, name: String? = nil) -> Action {
    savedAddress = address
    savedName = name
    attempts = 0
    nextDelay = initialDelayMs
    lastMatch = nil
    state = .connecting
    return .connect(address: address, delayMs: 0)
  }

  /// `bleForget`: drop the strap; nothing connects afterwards.
  func forget() -> Action {
    savedAddress = nil
    savedName = nil
    stop()
    return .nothing
  }

  /// Nobody wants the strap any more (run ended, Start/Ready left): the client closes everything.
  func stop() {
    connectedAt = nil
    seen.removeAll()
    state = .idle
  }

  /// The strap is wanted. Already hunting, connecting or connected: carry on. Otherwise hunt now.
  func onStart(nowMs: Int64) -> Action {
    guard savedAddress != nil, state == .idle else { return .nothing }
    attempts = 0
    nextDelay = initialDelayMs
    huntsThisEpisode = 0
    return hunt(nowMs: nowMs, delayMs: 0)
  }

  /// The hunt's pending connect to the saved identifier came up: it is now being set up, so the
  /// client stops the scan and later scan results are ignored.
  func onLinkUp() {
    guard state == .hunting else { return }
    lastMatch = .address
    state = .connecting
  }

  /// The first measurement arrived.
  func onConnected(nowMs: Int64) {
    connectedAt = nowMs
    attempts = 0
    huntsThisEpisode = 0
    state = .connected
  }

  /// The pairing scan (outside this object) also spends from the scan-start budget.
  func noteScanStart(nowMs: Int64) {
    prune(nowMs)
    scanStarts.append(nowMs)
  }

  func canStartScan(nowMs: Int64) -> Bool {
    prune(nowMs)
    return scanStarts.count < Self.scanStartsPerWindow
  }

  private func prune(_ nowMs: Int64) {
    scanStarts.removeAll { nowMs - $0 >= Self.scanWindowMs }
  }

  /// A hunt starting at `now + delay`, pushed later if the scan-start budget is spent.
  private func hunt(nowMs: Int64, delayMs: Int64) -> Action {
    guard let a = savedAddress else { return .nothing }
    prune(nowMs)
    var at = nowMs + delayMs
    if scanStarts.count >= Self.scanStartsPerWindow {
      let freeAt = scanStarts.sorted()[scanStarts.count - Self.scanStartsPerWindow] + Self.scanWindowMs
      at = max(at, freeAt)
    }
    scanStarts.append(at)
    seen.removeAll()
    state = .hunting
    let fast = huntsThisEpisode < Self.fastHunts
    huntsThisEpisode += 1
    return .hunt(delayMs: at - nowMs, scanMs: fast ? Self.fastScanMs : Self.huntScanMs, passiveAddress: a, lowLatency: fast)
  }

  /// One scan result during a hunt: connect the first one that is the saved strap.
  func onScanResult(_ c: Candidate, nowMs: Int64) -> Action {
    guard state == .hunting, savedAddress != nil else { return .nothing }
    if let i = seen.firstIndex(where: { $0.address == c.address }) { seen[i] = c } else { seen.append(c) }
    return evaluate()
  }

  /// Periodic re-check while hunting (a no-op today: every match is made on a scan result).
  func onHuntTick(nowMs: Int64) -> Action {
    guard state == .hunting, savedAddress != nil else { return .nothing }
    return evaluate()
  }

  private func evaluate() -> Action {
    guard let (c, how) = pick() else { return .nothing }
    savedAddress = c.address
    lastMatch = how
    state = .connecting
    return .connect(address: c.address, delayMs: 0)
  }

  private func pick() -> (Candidate, Match)? {
    if let c = seen.first(where: { $0.address == savedAddress }) { return (c, .address) }
    guard let n = savedName?.trimmingCharacters(in: .whitespaces), !n.isEmpty else { return nil }
    var best: Candidate?
    for c in seen where c.name?.trimmingCharacters(in: .whitespaces).caseInsensitiveCompare(n) == .orderedSame {
      if best == nil || c.rssi > best!.rssi { best = c }
    }
    return best.map { ($0, .name) }
  }

  /// The hunt's scan ended without a match (it ran its full length, or failed). Hunt again, after
  /// the backoff when it failed.
  func onScanEnded(nowMs: Int64, failed: Bool) -> Action {
    guard state == .hunting else { return .nothing }
    return hunt(nowMs: nowMs, delayMs: failed ? backoff() : 0)
  }

  /// The link dropped, a connect had no first measurement in time, or setup failed twice. While
  /// hunting this can only be the pending connect giving up: the scan carries on.
  func onDisconnected(nowMs: Int64) -> Action {
    guard savedAddress != nil, state != .idle, state != .hunting else { return .nothing }
    let stable = connectedAt.map { nowMs - $0 >= stableMs } ?? false
    connectedAt = nil
    if stable {
      nextDelay = initialDelayMs
      attempts = 0
    }
    return hunt(nowMs: nowMs, delayMs: backoff())
  }

  func onConnectFailed(nowMs: Int64) -> Action { onDisconnected(nowMs: nowMs) }

  private func backoff() -> Int64 {
    let d = nextDelay
    attempts += 1
    nextDelay = min(nextDelay * 2, maxDelayMs)
    return d
  }
}
