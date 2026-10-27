import XCTest

@testable import Runner

// Strap support: the 0x2A37 parser against the vectors shared with Kotlin, the reconnect policy
// (ported from BleTest.kt), and BleHrClient driven by a fake central and a manual clock.

private func data(_ v: [Int]) -> Data { Data(v.map { UInt8($0) }) }

final class HeartRateMeasurementTests: XCTestCase {
  private struct Vectors: Decodable {
    struct Parsed: Decodable {
      let bpm: Int?
      let rawBpm: Int
      let sixteenBit: Bool
      let contactSupported: Bool
      let contactDetected: Bool
      let energyKj: Int?
      let rrRaw: [Int]
    }
    struct Row: Decodable {
      let name: String
      let bytes: [Int]
      let kotlin: Bool
      let parsed: Parsed?
    }
    let vectors: [Row]
  }

  /// Located through `#filePath` like the GPX route: the simulator shares the host file system.
  private func load() throws -> Vectors {
    let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Resources/ble-hr-vectors.json")
    return try JSONDecoder().decode(Vectors.self, from: Data(contentsOf: url))
  }

  func testEverySharedVectorParsesAsExpected() throws {
    let rows = try load().vectors
    XCTAssertGreaterThanOrEqual(rows.count, 12)
    for row in rows {
      let got = HeartRateMeasurement.parse(data(row.bytes))
      guard let want = row.parsed else {
        XCTAssertNil(got, row.name)
        continue
      }
      let m = try XCTUnwrap(got, row.name)
      XCTAssertEqual(m.bpm, want.bpm, row.name)
      XCTAssertEqual(m.rawBpm, want.rawBpm, row.name)
      XCTAssertEqual(m.sixteenBit, want.sixteenBit, row.name)
      XCTAssertEqual(m.contactSupported, want.contactSupported, row.name)
      XCTAssertEqual(m.contactDetected, want.contactDetected, row.name)
      XCTAssertEqual(m.energyExpendedKj, want.energyKj, row.name)
      XCTAssertEqual(m.rrRaw, want.rrRaw, row.name)
    }
  }

  func testRrIntervalsConvertToMilliseconds() throws {
    let m = try XCTUnwrap(HeartRateMeasurement.parse(data([0x10, 0x64, 0x00, 0x04])))
    XCTAssertEqual(m.rrMs, [1000.0])
  }
}

final class BleReconnectPolicyTests: XCTestCase {
  typealias P = BleReconnectPolicy
  private func cand(_ a: String, _ n: String?, _ rssi: Int = -60) -> P.Candidate { .init(address: a, name: n, rssi: rssi) }
  private func fastHunt(_ passive: String, _ delay: Int64 = 0) -> P.Action {
    .hunt(delayMs: delay, scanMs: P.fastScanMs, passiveAddress: passive, lowLatency: true)
  }

  func testPairingConnectsDirectlyEveryOtherConnectStartsWithAHunt() {
    let p = P(address: nil)
    XCTAssertEqual(p.onStart(nowMs: 0), .nothing)
    XCTAssertEqual(p.onDisconnected(nowMs: 0), .nothing)
    XCTAssertEqual(p.pair(address: "AA", name: "WHOOP 4A0934"), .connect(address: "AA", delayMs: 0))
    XCTAssertEqual(p.state, .connecting)
    XCTAssertEqual(p.onStart(nowMs: 1_000), .nothing)
    p.onConnected(nowMs: 2_000)
    XCTAssertEqual(p.onStart(nowMs: 3_000), .nothing)
    p.stop()
    XCTAssertEqual(p.state, .idle)
    XCTAssertEqual(p.onStart(nowMs: 100_000), fastHunt("AA"))
    XCTAssertEqual(p.state, .hunting)
    _ = p.forget()
    XCTAssertNil(p.savedAddress)
    XCTAssertEqual(p.onStart(nowMs: 200_000), .nothing)
    XCTAssertEqual(p.onConnectFailed(nowMs: 200_000), .nothing)
  }

  func testStaleIdentifierIsFoundByNameAndTheSavedOneFollowsIt() {
    let p = P(address: "OLD", name: "WHOOP 4A0934")
    _ = p.onStart(nowMs: 0)
    XCTAssertEqual(p.onScanResult(cand("X1", "Polar H10", -40), nowMs: 500), .nothing, "another strap is never taken")
    XCTAssertEqual(p.onScanResult(cand("NEW", "whoop 4a0934", -70), nowMs: 900), .connect(address: "NEW", delayMs: 0))
    XCTAssertEqual(p.savedAddress, "NEW")
    XCTAssertEqual(p.lastMatch, .name)
    XCTAssertEqual(p.onScanResult(cand("NEW2", "WHOOP 4A0934"), nowMs: 1_000), .nothing, "results after a match are ignored")
  }

  func testSavedIdentifierSeenByTheScanIsConnectedDirectly() {
    let p = P(address: "AA", name: "Polar H10 1234")
    _ = p.onStart(nowMs: 0)
    XCTAssertEqual(p.onScanResult(cand("AA", nil), nowMs: 300), .connect(address: "AA", delayMs: 0))
    XCTAssertEqual(p.lastMatch, .address)
  }

  func testPendingConnectComingUpEndsTheHunt() {
    let p = P(address: "AA", name: "Polar H10 1234")
    _ = p.onStart(nowMs: 0)
    XCTAssertEqual(p.onDisconnected(nowMs: 1_000), .nothing, "the pending connect giving up: the scan carries on")
    XCTAssertEqual(p.state, .hunting)
    p.onLinkUp()
    XCTAssertEqual(p.state, .connecting)
    XCTAssertEqual(p.onScanResult(cand("AA", "Polar H10 1234"), nowMs: 2_000), .nothing)
  }

  func testAStrangersStrapOfTheSameBrandIsNeverTaken() {
    let p = P(address: "OLD", name: "WHOOP 4A0934")
    _ = p.onStart(nowMs: 0)
    XCTAssertEqual(p.onScanResult(cand("N1", "WHOOP 4C1111", -40), nowMs: 500), .nothing)
    XCTAssertEqual(p.onHuntTick(nowMs: 60_000), .nothing)
    XCTAssertEqual(p.state, .hunting)
    XCTAssertEqual(p.savedAddress, "OLD")
    XCTAssertEqual(p.onScanResult(cand("NEW", "WHOOP 4A0934", -80), nowMs: 62_000), .connect(address: "NEW", delayMs: 0))
  }

  func testWithoutASavedNameOnlyTheSavedIdentifierMatches() {
    let p = P(address: "OLD", name: nil)
    _ = p.onStart(nowMs: 0)
    XCTAssertEqual(p.onScanResult(cand("NEW", "WHOOP 4A0934"), nowMs: 500), .nothing)
    XCTAssertEqual(p.onScanResult(cand("OLD", nil), nowMs: 61_000), .connect(address: "OLD", delayMs: 0))
  }

  func testAScanThatEndsWithoutAMatchHuntsAgain() {
    let p = P(address: "OLD", name: "WHOOP 4A0934")
    XCTAssertEqual(p.onStart(nowMs: 0), fastHunt("OLD"))
    XCTAssertEqual(p.onScanEnded(nowMs: P.fastScanMs, failed: false), fastHunt("OLD"))
    XCTAssertEqual(
      p.onScanEnded(nowMs: 2 * P.fastScanMs, failed: false),
      .hunt(delayMs: 0, scanMs: P.huntScanMs, passiveAddress: "OLD", lowLatency: false))
    let q = P(address: "OLD", name: "WHOOP 4A0934")
    _ = q.onStart(nowMs: 0)
    XCTAssertEqual(q.onScanEnded(nowMs: 1_000, failed: true), fastHunt("OLD", 500).withScan(P.fastScanMs))
  }

  func testDropsHuntAgainWithBackoffAndAStableLinkResetsIt() {
    let p = P(address: "A", name: "WHOOP 1")
    _ = p.onStart(nowMs: 0)
    _ = p.onScanResult(cand("A", "WHOOP 1"), nowMs: 1)
    p.onConnected(nowMs: 1_000)
    var delays: [Int64] = []
    for i in 1...6 {
      let t = Int64(i) * 100_000
      guard case .hunt(let delay, _, let passive, _) = p.onConnectFailed(nowMs: t) else { return XCTFail("expected a hunt") }
      XCTAssertEqual(passive, "A")
      _ = p.onScanResult(cand("A", "WHOOP 1"), nowMs: t + 1)
      delays.append(delay)
    }
    XCTAssertEqual(delays, [500, 1_000, 2_000, 4_000, 8_000, 8_000])
    p.onConnected(nowMs: 1_000_000)
    guard case .hunt(let delay, _, _, let fast) = p.onDisconnected(nowMs: 1_010_000) else { return XCTFail("expected a hunt") }
    XCTAssertEqual(delay, 500)
    XCTAssertEqual(p.attempts, 1)
    XCTAssertTrue(fast, "a drop after a working link looks fast again")
  }

  func testAHuntOverTheScanStartBudgetIsDelayedNeverDropped() {
    let p = P(address: "OLD", name: "WHOOP 4A0934")
    for i in 0..<P.scanStartsPerWindow { p.noteScanStart(nowMs: 1_000 + Int64(i)) }
    XCTAssertFalse(p.canStartScan(nowMs: 10_000))
    guard case .hunt(let delay, _, _, _) = p.onStart(nowMs: 10_000) else { return XCTFail("expected a hunt") }
    XCTAssertEqual(delay, 1_000 + P.scanWindowMs - 10_000)
    XCTAssertFalse(p.canStartScan(nowMs: 10_000), "the planned hunt holds a slot too")
    XCTAssertTrue(p.canStartScan(nowMs: 80_000))
  }
}

private extension BleReconnectPolicy.Action {
  /// Test helper: the same hunt with a different scan length (the failed-scan retry still starts a fast hunt).
  func withScan(_ ms: Int64) -> BleReconnectPolicy.Action {
    if case .hunt(let d, _, let p, let l) = self { return .hunt(delayMs: d, scanMs: ms, passiveAddress: p, lowLatency: l) }
    return self
  }
}

// MARK: fakes

final class ManualScheduler: BleScheduling {
  private final class Timer: Cancelling {
    let at: Int64
    let block: () -> Void
    var cancelled = false
    init(at: Int64, block: @escaping () -> Void) { self.at = at; self.block = block }
    func cancel() { cancelled = true }
  }
  private var timers: [Timer] = []
  private(set) var now: Int64 = 1_000_000

  func nowMs() -> Int64 { now }

  func after(_ ms: Int64, _ block: @escaping () -> Void) -> Cancelling {
    let t = Timer(at: now + ms, block: block)
    timers.append(t)
    return t
  }

  /// Runs due timers in time order, including ones they schedule.
  func advance(_ ms: Int64) {
    let target = now + ms
    while let next = timers.filter({ !$0.cancelled && $0.at <= target }).min(by: { $0.at < $1.at }) {
      timers.removeAll { $0 === next }
      now = max(now, next.at)
      next.block()
    }
    now = target
    timers.removeAll { $0.cancelled }
  }
}

final class FakeCentral: BleCentral {
  weak var delegate: BleCentralDelegate?
  var poweredOn = true
  var authorized = true
  /// False while the system Bluetooth prompt is up (first use).
  var stateResolved = true
  private(set) var scanning = false
  private(set) var scanStarts = 0
  var known: Set<String> = []
  private(set) var connects: [String] = []
  private(set) var cancels: [String] = []
  private(set) var setups: [String] = []

  func startScan() -> Bool {
    guard poweredOn else { return false }
    scanning = true
    scanStarts += 1
    return true
  }
  func stopScan() { scanning = false }
  func connect(id: String) -> Bool {
    guard known.contains(id) else { return false }
    connects.append(id)
    return true
  }
  func cancel(id: String) { cancels.append(id) }
  func beginSetup(id: String) { setups.append(id) }

  // Driving the client.
  func advertise(_ id: String, _ name: String?, rssi: Int = -60) {
    known.insert(id)
    delegate?.central(didDiscover: BleAdvert(id: id, name: name, rssi: rssi))
  }
  func linkUp(_ id: String) { delegate?.centralDidConnect(id: id) }
  func notifying(_ id: String) { delegate?.centralNotificationsReady(id: id) }
  func reading(_ id: String, _ bytes: [Int]) { delegate?.central(id: id, didReceive: data(bytes)) }
  func drop(_ id: String) { delegate?.centralDidDisconnect(id: id) }
  func setPower(_ on: Bool) { poweredOn = on; delegate?.centralDidChangeState() }
  /// The runner answered the permission prompt.
  func answerPrompt(allow: Bool, on: Bool = true) {
    stateResolved = true
    authorized = allow
    poweredOn = allow && on
    delegate?.centralDidChangeState()
  }
}

final class MemoryStore: BleStrapStore {
  var address: String?
  var name: String?
  init(address: String? = nil, name: String? = nil) { self.address = address; self.name = name }
}

final class RecordingListener: BleHrListener {
  var readings: [(t: Int64, bpm: Int)] = []
  var noContact = 0
  var links: [Bool] = []
  func onReading(t: Int64, bpm: Int) { readings.append((t, bpm)) }
  func onNoContact() { noContact += 1 }
  func onLink(connected: Bool) { links.append(connected) }
}

final class BleHrClientTests: XCTestCase {
  private var central: FakeCentral!
  private var clock: ManualScheduler!
  private var store: MemoryStore!
  private var listener: RecordingListener!
  private var created = 0
  private var log: [String] = []

  private func makeClient(address: String? = nil, name: String? = nil, isBackground: @escaping () -> Bool = { false }) -> BleHrClient {
    central = FakeCentral()
    clock = ManualScheduler()
    store = MemoryStore(address: address, name: name)
    listener = RecordingListener()
    created = 0
    let c = central!
    let client = BleHrClient(makeCentral: { [unowned self] in created += 1; return c }, scheduler: clock, store: store, trace: { [unowned self] in log.append($0) }, isBackground: isBackground)
    client.listener = listener
    return client
  }

  /// Hunt to a working link: strap appears at `id` with `name`, notifies, sends a reading.
  private func bringUp(_ client: BleHrClient, id: String, name: String?, bpm: [Int] = [0x00, 0x96]) {
    client.startScreenWants()
    clock.advance(0)
    central.advertise(id, name)
    clock.advance(0)
    central.linkUp(id)
    central.notifying(id)
    central.reading(id, bpm)
  }

  func testNoCentralIsCreatedWithoutAPairedStrap() {
    let client = makeClient()
    client.startScreenWants()
    client.connectIfPaired()
    clock.advance(60_000)
    XCTAssertEqual(created, 0, "no strap, no Bluetooth permission prompt")
  }

  func testPairingScanListsHrDevicesDedupedAndKeepsTheirNames() {
    let client = makeClient()
    var result: Result<[BleAdvert], BleHrClient.ScanError>?
    client.scan { result = $0 }
    XCTAssertTrue(central.scanning)
    central.advertise("A1", nil)
    central.advertise("A1", "WHOOP 4A0934")
    central.advertise("B2", "Polar H10 1234")
    clock.advance(10_000)
    XCTAssertFalse(central.scanning)
    let found = try? result?.get()
    XCTAssertEqual(found?.map(\.id), ["A1", "B2"])
    XCTAssertEqual(found?.first?.name, "WHOOP 4A0934")
  }

  func testScanFailsCleanlyWhenBluetoothIsOffOrDenied() {
    let client = makeClient()
    central.authorized = false
    var r1: Result<[BleAdvert], BleHrClient.ScanError>?
    client.scan { r1 = $0 }
    XCTAssertEqual(r1?.failureValue, .notAuthorized)

    central.authorized = true
    central.poweredOn = false
    var r2: Result<[BleAdvert], BleHrClient.ScanError>?
    client.scan { r2 = $0 }
    XCTAssertEqual(r2?.failureValue, .bluetoothOff, "off is reported at once, not after a wait")
  }

  func testFirstPairingWaitsForThePermissionPromptInsteadOfFailingAsBluetoothOff() {
    let client = makeClient()
    central.poweredOn = false
    central.stateResolved = false  // prompt on screen
    var result: Result<[BleAdvert], BleHrClient.ScanError>?
    client.scan { result = $0 }
    clock.advance(10_000)  // the old 4 s timer would have failed this
    XCTAssertNil(result, "still waiting on the runner")
    central.answerPrompt(allow: true)
    XCTAssertTrue(central.scanning)
    central.advertise("A1", "WHOOP 4A0934")
    clock.advance(10_000)
    XCTAssertEqual(try? result?.get().map(\.id), ["A1"])
  }

  func testDenyingThePromptReadsAsNotAuthorizedAndBluetoothOffAfterItAsOff() {
    let client = makeClient()
    central.poweredOn = false
    central.stateResolved = false
    var denied: Result<[BleAdvert], BleHrClient.ScanError>?
    client.scan { denied = $0 }
    central.answerPrompt(allow: false)
    XCTAssertEqual(denied?.failureValue, .notAuthorized)

    let other = makeClient()
    central.poweredOn = false
    central.stateResolved = false
    var off: Result<[BleAdvert], BleHrClient.ScanError>?
    other.scan { off = $0 }
    central.answerPrompt(allow: true, on: false)  // allowed, but the radio is off
    XCTAssertEqual(off?.failureValue, .bluetoothOff)
  }

  func testManagerThatNeverReportsStopsWaitingAtTheCap() {
    let client = makeClient()
    central.poweredOn = false
    central.stateResolved = false
    var result: Result<[BleAdvert], BleHrClient.ScanError>?
    client.scan { result = $0 }
    clock.advance(BleHrClient.readyWaitMs - 1)
    XCTAssertNil(result)
    clock.advance(1)
    XCTAssertEqual(result?.failureValue, .bluetoothOff)
  }

  // MARK: background rescan

  private var background = false

  private func makeBackgroundClient(address: String? = "S1", name: String? = "WHOOP 4A0934") -> BleHrClient {
    let c = makeClient(address: address, name: name, isBackground: { [unowned self] in background })
    return c
  }

  func testBackgroundHuntRestartsTheScanEveryTwelveSecondsWhileLookingForANamedStrap() {
    background = true
    let client = makeBackgroundClient()
    client.startScreenWants()
    clock.advance(0)
    XCTAssertEqual(central.scanStarts, 1)
    clock.advance(BleHrClient.backgroundRescanMs - 1_000)
    XCTAssertEqual(central.scanStarts, 1)
    clock.advance(1_000)
    XCTAssertEqual(central.scanStarts, 2, "restarted at 12 s")
    XCTAssertTrue(central.scanning)
    clock.advance(BleHrClient.backgroundRescanMs)
    XCTAssertEqual(central.scanStarts, 3)
    // A name that now shows up is matched on the fresh discovery.
    central.advertise("NEW", "WHOOP 4A0934")
    clock.advance(0)
    XCTAssertEqual(central.connects.last, "NEW")
  }

  func testNoBackgroundRescanInTheForegroundWithoutASavedNameOrAfterTheLinkIsUp() {
    background = false
    let fg = makeBackgroundClient()
    fg.startScreenWants()
    clock.advance(40_000)
    XCTAssertEqual(central.scanStarts, 1, "foreground keeps one scan")

    background = true
    let noName = makeBackgroundClient(address: "S1", name: nil)
    noName.startScreenWants()
    clock.advance(40_000)
    XCTAssertEqual(central.scanStarts, 1, "an identifier-only strap comes back via the pending connect")

    let up = makeBackgroundClient()
    up.startScreenWants()
    clock.advance(0)
    central.advertise("S1", "WHOOP 4A0934")
    clock.advance(0)
    central.linkUp("S1")
    central.notifying("S1")
    central.reading("S1", [0x00, 0x96])
    let starts = central.scanStarts
    clock.advance(60_000)
    XCTAssertEqual(central.scanStarts, starts, "no rescans once connected")
  }

  func testPairSavesIdentifierAndNameAndConnectsOnlyAfterTheFirstMeasurement() {
    let client = makeClient()
    client.scan { _ in }
    central.advertise("A1", "WHOOP 4A0934")
    clock.advance(10_000)
    client.pair(address: "A1")
    clock.advance(0)
    XCTAssertEqual(store.address, "A1")
    XCTAssertEqual(store.name, "WHOOP 4A0934")
    XCTAssertEqual(central.connects, ["A1"])
    central.linkUp("A1")
    XCTAssertEqual(central.setups, ["A1"])
    central.notifying("A1")
    XCTAssertFalse(client.connected, "notifications alone are not a working strap")
    central.reading("A1", [0x00, 0x96])
    XCTAssertTrue(client.connected)
    XCTAssertEqual(client.lastHr, 150)
    XCTAssertEqual(listener.links, [true])
    XCTAssertEqual(listener.readings.map(\.bpm), [150])
  }

  func testSavedStrapIsHuntedWithAScanAndAPendingConnect() {
    let client = makeClient(address: "S1", name: "WHOOP 4A0934")
    central.known = ["S1"]
    client.startScreenWants()
    clock.advance(0)
    XCTAssertTrue(central.scanning)
    XCTAssertEqual(central.connects, ["S1"], "pending connect to the saved identifier")
    central.linkUp("S1")  // the strap kept its identifier and came back on its own
    XCTAssertFalse(central.scanning, "link up ends the hunt scan")
    central.notifying("S1")
    central.reading("S1", [0x00, 0x90])
    XCTAssertTrue(client.connected)
  }

  func testStaleSavedIdentifierFallsBackToTheSavedNameAndRepointsTheStore() {
    let client = makeClient(address: "OLD", name: "WHOOP 4A0934")
    client.startScreenWants()
    clock.advance(0)
    central.advertise("STRANGER", "WHOOP 4C1111", rssi: -30)
    clock.advance(0)
    XCTAssertEqual(central.connects, [], "a stranger's strap of the same brand is not taken")
    central.advertise("NEW", "whoop 4a0934", rssi: -80)
    clock.advance(0)
    XCTAssertEqual(central.connects, ["NEW"])
    XCTAssertEqual(store.address, "NEW")
    XCTAssertEqual(store.name, "WHOOP 4A0934")
    central.linkUp("NEW")
    central.notifying("NEW")
    central.reading("NEW", [0x00, 0x80])
    XCTAssertTrue(client.connected)
    XCTAssertEqual(client.savedAddress, "NEW")
  }

  func testNoContactPacketReportsNoContactAndNeverZeroBpm() {
    let client = makeClient(address: "S1", name: "X")
    bringUp(client, id: "S1", name: "X")
    central.reading("S1", [0x04, 0x48])  // contact supported, not detected
    XCTAssertEqual(listener.noContact, 1)
    XCTAssertNil(client.lastHr)
    central.reading("S1", [0x00, 0x00])
    XCTAssertEqual(listener.noContact, 2)
    XCTAssertEqual(listener.readings.map(\.bpm), [150])
  }

  func testDropHuntsAgainAfterTheBackoffAndTheHrIsCleared() {
    let client = makeClient(address: "S1", name: "X")
    bringUp(client, id: "S1", name: "X")
    XCTAssertTrue(client.connected)
    let scansBefore = central.scanStarts
    central.drop("S1")
    XCTAssertFalse(client.connected)
    XCTAssertNil(client.lastHr)
    XCTAssertEqual(listener.links, [true, false])
    clock.advance(499)
    XCTAssertEqual(central.scanStarts, scansBefore, "backoff 0.5 s first")
    clock.advance(1)
    XCTAssertEqual(central.scanStarts, scansBefore + 1)
    XCTAssertTrue(central.scanning)
  }

  func testStaleCallbackFromAReplacedLinkIsIgnored() {
    let client = makeClient(address: "S1", name: "X")
    bringUp(client, id: "S1", name: "X")
    central.drop("S1")
    clock.advance(500)  // hunting again; link is gone
    let links = listener.links
    central.drop("OTHER")
    central.linkUp("OTHER")
    central.reading("OTHER", [0x00, 0x99])
    XCTAssertEqual(listener.links, links)
    XCTAssertEqual(listener.readings.count, 1)
    XCTAssertTrue(central.cancels.contains("OTHER"), "a connect we did not ask for is cancelled")
  }

  func testDirectConnectWithNoMeasurementWithinTheWindowHuntsAgain() {
    let client = makeClient(address: "S1", name: "X")
    client.startScreenWants()
    clock.advance(0)
    central.advertise("S1", "X")
    clock.advance(0)
    central.linkUp("S1")
    let scans = central.scanStarts
    clock.advance(BleHrClient.connectWindowMs)
    XCTAssertFalse(client.connected)
    clock.advance(500)
    XCTAssertEqual(central.scanStarts, scans + 1)
  }

  func testLinkThatNeverSendsAMeasurementIsDroppedAndHuntedAgain() {
    let client = makeClient(address: "S1", name: "X")
    client.startScreenWants()
    clock.advance(0)
    central.advertise("S1", "X")
    clock.advance(0)
    central.linkUp("S1")
    central.notifying("S1")
    let scans = central.scanStarts
    clock.advance(BleHrClient.connectWindowMs)  // the connect window (10 s) fires before the 15 s watchdog
    XCTAssertFalse(client.connected)
    XCTAssertTrue(central.cancels.contains("S1"))
    clock.advance(500)
    XCTAssertEqual(central.scanStarts, scans + 1)
  }

  func testSetupFailsTwiceThenDropsAndHunts() {
    let client = makeClient(address: "S1", name: "X")
    client.startScreenWants()
    clock.advance(0)
    central.advertise("S1", "X")
    clock.advance(0)
    central.linkUp("S1")
    central.delegate?.centralSetupFailed(id: "S1", what: "services")
    clock.advance(BleHrClient.setupRetryMs)
    XCTAssertEqual(central.setups.count, 2, "retried once")
    let scans = central.scanStarts
    central.delegate?.centralSetupFailed(id: "S1", what: "services")
    XCTAssertTrue(central.cancels.contains("S1"))
    clock.advance(500)
    XCTAssertEqual(central.scanStarts, scans + 1)
  }

  func testLetsGoOfTheStrapOnlyAfterEveryOwnerReleasedAndTheLinger() {
    let client = makeClient(address: "S1", name: "X")
    client.startScreenWants()
    client.connectIfPaired()
    clock.advance(0)
    central.advertise("S1", "X")
    clock.advance(0)
    central.linkUp("S1")
    central.notifying("S1")
    central.reading("S1", [0x00, 0x96])
    client.startScreenReleases()
    clock.advance(BleHrClient.lingerMs + 1)
    XCTAssertTrue(client.connected, "the run still wants it")
    client.disconnect()
    clock.advance(BleHrClient.lingerMs - 1)
    XCTAssertTrue(client.connected, "Ready -> GO keeps the warm link through the linger")
    clock.advance(2)
    XCTAssertFalse(client.connected)
    XCTAssertTrue(central.cancels.contains("S1"))
  }

  func testForgetClearsTheStoreAndDropsTheLink() {
    let client = makeClient(address: "S1", name: "X")
    bringUp(client, id: "S1", name: "X")
    client.forget()
    XCTAssertNil(store.address)
    XCTAssertNil(store.name)
    XCTAssertFalse(client.connected)
    clock.advance(60_000)
    XCTAssertFalse(central.scanning)
  }

  func testBluetoothSwitchedOffMidRunRecoversWhenItComesBack() {
    let client = makeClient(address: "S1", name: "X")
    bringUp(client, id: "S1", name: "X")
    central.setPower(false)
    XCTAssertFalse(client.connected)
    clock.advance(20_000)  // backoff retries find Bluetooth still off and keep waiting
    XCTAssertFalse(central.scanning)
    central.setPower(true)
    clock.advance(60_000)  // the scan-start budget may have pushed the next hunt out to 30 s
    XCTAssertTrue(central.scanning, "hunting again once Bluetooth is back")
  }

  func testRecorderBridgeFeedsFreshReadingsOnly() {
    var t: Int64 = 100
    let bridge = RecorderStrapBridge(host: RecorderHost(root: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("br-" + UUID().uuidString)), nowMs: { t })
    bridge.onLink(connected: true)
    bridge.onReading(t: 100, bpm: 150)
    XCTAssertEqual(bridge.snapshot.bpm, 150)
    t = 2_100
    XCTAssertEqual(bridge.snapshot.bpm, 150)
    t = 2_101
    XCTAssertNil(bridge.snapshot.bpm, "older than 2 s is not shown")
    XCTAssertTrue(bridge.snapshot.connected)
    bridge.onLink(connected: false)
    XCTAssertFalse(bridge.snapshot.connected)
  }
}

private extension Result {
  var failureValue: Failure? {
    if case .failure(let e) = self { return e }
    return nil
  }
}
