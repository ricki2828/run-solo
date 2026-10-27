import Foundation

/// Heart Rate Profile client, the iOS counterpart of Android's `BleHrClient`: same owners,
/// linger, hunt, connect window, silent-link watchdog and setup retry, with every connect decision
/// delegated to `BleReconnectPolicy`. Everything runs on the main queue.
///
/// Pairing is one filtered scan for 0x180D. Every later connection is a hunt (one long scan plus a
/// pending connect to the saved identifier); the saved identifier and name follow the strap, so a
/// strap whose identifier changed is still found by its advertised name (Android #290/#336).
/// "Connected" is reported only once notifications are on AND the first measurement has arrived.
///
/// The CoreBluetooth manager is created lazily, on the first scan or the first connect for a saved
/// strap, so a runner who never pairs one never sees the Bluetooth permission prompt.
/// Strap events for the recorder (HR with the monotonic receipt time, no-contact, link up/down).
protocol BleHrListener: AnyObject {
  func onReading(t: Int64, bpm: Int)
  func onNoContact()
  func onLink(connected: Bool)
}

final class BleHrClient: BleCentralDelegate {
  enum ScanError: Error, Equatable { case bluetoothOff, notAuthorized, budgetSpent, couldNotStart }

  static let ownerStart = "start"
  static let ownerRun = "run"
  static let ownerPair = "pair"
  static let silentLinkMs: Int64 = 15_000
  static let connectWindowMs: Int64 = 10_000
  static let huntTickMs: Int64 = 1_000
  static let lingerMs: Int64 = 5_000
  static let pairHoldMs: Int64 = 120_000
  static let setupRetryMs: Int64 = 500
  static let maxSeenNames = 32
  /// Waiting for CoreBluetooth to report its first state (the permission prompt is up).
  static let readyWaitMs: Int64 = 4_000

  weak var listener: BleHrListener?

  private let makeCentral: () -> BleCentral
  private let scheduler: BleScheduling
  private let store: BleStrapStore
  private let trace: (String) -> Void
  private let policy: BleReconnectPolicy
  private var central: BleCentral?

  private var link: String?  // the identifier we are connected / connecting to
  private var pending: Cancelling?
  private var setupRetried = false
  private var notificationsOn = false
  private var silentWatchdog: Cancelling?
  private var connectWindow: Cancelling?
  private var huntToken = 0  // 0 = no hunt scan running
  private var huntCounter = 0
  private var huntEnd: Cancelling?
  private var huntTick: Cancelling?
  private var huntSeen = Set<String>()
  private var owners = Set<String>()
  private var linger: Cancelling?
  private var seenNames: [String: String] = [:]
  private var pairScan: PairScan?
  private var readyWaiters: [(token: Int, fire: (Bool) -> Void)] = []
  private var waiterCounter = 0

  private final class PairScan {
    var found: [String: BleAdvert] = [:]
    var order: [String] = []
    var finished = false
  }

  private(set) var connected = false
  private(set) var lastHr: Int?
  private(set) var deviceName: String?
  var savedAddress: String? { policy.savedAddress }
  var adapterOn: Bool { central?.poweredOn ?? false }

  init(
    makeCentral: @escaping () -> BleCentral, scheduler: BleScheduling = MainScheduler(),
    store: BleStrapStore = DefaultsStrapStore(), trace: @escaping (String) -> Void = { _ in }
  ) {
    self.makeCentral = makeCentral
    self.scheduler = scheduler
    self.store = store
    self.trace = trace
    policy = BleReconnectPolicy(address: store.address, name: store.name)
    deviceName = store.name
  }

  private func now() -> Int64 { scheduler.nowMs() }

  private func ensureCentral() -> BleCentral {
    if let central { return central }
    let c = makeCentral()
    c.delegate = self
    central = c
    return c
  }

  /// Last four characters only: enough to tell identifiers apart in the log.
  private func id4(_ id: String) -> String { "…" + id.suffix(4) }

  // MARK: pairing

  /// One filtered scan for HR peripherals, up to `timeoutMs`; results de-duplicated by identifier.
  func scan(timeoutMs: Int64 = 10_000, done: @escaping (Result<[BleAdvert], ScanError>) -> Void) {
    let c = ensureCentral()
    if !c.authorized { return done(.failure(.notAuthorized)) }
    whenReady(c) { [self] ready in
      guard ready else { return done(.failure(c.authorized ? .bluetoothOff : .notAuthorized)) }
      guard pairScan == nil else { return done(.failure(.couldNotStart)) }
      guard policy.canStartScan(nowMs: now()) else {
        trace("scan refused: start budget spent")
        return done(.failure(.budgetSpent))
      }
      policy.noteScanStart(nowMs: now())
      // The hunt's scan (if running) already delivers adverts; one CB scan serves both.
      if huntToken == 0, !c.startScan() { return done(.failure(.couldNotStart)) }
      let scan = PairScan()
      pairScan = scan
      _ = scheduler.after(timeoutMs) { [self] in
        guard !scan.finished else { return }
        scan.finished = true
        pairScan = nil
        if huntToken == 0 { c.stopScan() }
        done(.success(scan.order.compactMap { scan.found[$0] }))
      }
    }
  }

  /// Runs `fire(true)` once the manager is powered on; `fire(false)` when Bluetooth is off or
  /// denied, or nothing was reported within `readyWaitMs`.
  private func whenReady(_ c: BleCentral, _ fire: @escaping (Bool) -> Void) {
    if c.poweredOn { return fire(true) }
    if !c.authorized { return fire(false) }
    waiterCounter += 1
    let token = waiterCounter
    readyWaiters.append((token, fire))
    _ = scheduler.after(Self.readyWaitMs) { [self] in
      guard let i = readyWaiters.firstIndex(where: { $0.token == token }) else { return }
      let w = readyWaiters.remove(at: i)
      w.fire(c.poweredOn)
    }
  }

  func pair(address: String) {
    // The scan's name wins: the OS only knows a remote name it has cached.
    let name = seenNames[address]
    store.address = address
    store.name = name
    deviceName = name
    trace("pair \(id4(address)) name=\(name ?? "-")")
    // Pairing holds the strap for a while (the pairing screen shows its HR) even outside Start/Ready.
    want(Self.ownerPair, start: false)
    _ = scheduler.after(Self.pairHoldMs) { [self] in release(Self.ownerPair) }
    apply(policy.pair(address: address, name: name))
  }

  func forget() {
    store.address = nil
    store.name = nil
    deviceName = nil
    trace("forget")
    shutdown()
    apply(policy.forget())
  }

  // MARK: owners

  /// Recording starts: keep a working link, otherwise hunt for the saved strap.
  func connectIfPaired() { want(Self.ownerRun) }

  /// Recording stopped: let go unless the Start/Ready screen still wants it.
  func disconnect() { release(Self.ownerRun) }

  /// The Start/Ready GPS probe started: connect the saved strap before GO.
  func startScreenWants() { want(Self.ownerStart) }

  func startScreenReleases() { release(Self.ownerStart) }

  private func want(_ owner: String, start: Bool = true) {
    linger?.cancel()
    linger = nil
    if owners.insert(owner).inserted { trace("want \(owner) owners=\(owners.sorted()) state=\(policy.state)") }
    if connected, link != nil { listener?.onLink(connected: true) }
    if start { apply(policy.onStart(nowMs: now())) }
  }

  private func release(_ owner: String) {
    guard owners.remove(owner) != nil else { return }
    trace("release \(owner) owners=\(owners.sorted())")
    if !owners.isEmpty || linger != nil { return }
    linger = scheduler.after(Self.lingerMs) { [self] in
      linger = nil
      if owners.isEmpty {
        trace("idle: letting go of the strap")
        shutdown()
      }
    }
  }

  /// Close everything; nothing connects again until someone wants the strap.
  private func shutdown() {
    cancelPending()
    connectWindow?.cancel()
    connectWindow = nil
    stopHunt()
    closeLink()
    policy.stop()
    setConnected(false)
  }

  // MARK: policy actions

  private func apply(_ action: BleReconnectPolicy.Action) {
    switch action {
    case .nothing:
      break
    case .connect(let address, let delayMs):
      persistIdentity()
      schedule(delayMs) { [self] in
        stopHunt()
        closeLink()
        connect(address, passive: false)
      }
    case .hunt(let delayMs, _, _, _):
      stopHunt()
      closeLink()
      connectWindow?.cancel()
      connectWindow = nil
      if delayMs > 0 { trace("hunt in \(delayMs)ms") }
      schedule(delayMs) { [self] in startHunt(action) }
    }
  }

  private func schedule(_ delayMs: Int64, _ block: @escaping () -> Void) {
    cancelPending()
    pending = scheduler.after(delayMs) { [self] in
      pending = nil
      block()
    }
  }

  private func cancelPending() {
    pending?.cancel()
    pending = nil
  }

  /// The policy re-points the saved identifier to the strap a scan found by identifier or name.
  private func persistIdentity() {
    let a = policy.savedAddress
    let n = policy.savedName
    if a != store.address || n != store.name {
      store.address = a
      store.name = n
      deviceName = n
      trace("saved strap re-pointed to \(a.map(id4) ?? "-") name=\(n ?? "-") match=\(String(describing: policy.lastMatch))")
    }
  }

  private func connect(_ id: String, passive: Bool) {
    let c = ensureCentral()
    guard c.poweredOn, c.authorized else {
      trace("connect skipped: powered=\(c.poweredOn) authorized=\(c.authorized)")
      if !passive { apply(policy.onConnectFailed(nowMs: now())) }
      return
    }
    setupRetried = false
    // A direct connect goes to an identifier a scan (or pairing) just saw: it must deliver within seconds.
    if !passive { armConnectWindow() }
    trace("connect \(id4(id)) passive=\(passive)")
    if c.connect(id: id) {
      link = id
    } else {
      trace("connect: \(id4(id)) unknown to this device")
      if !passive {
        connectWindow?.cancel()
        connectWindow = nil
        apply(policy.onConnectFailed(nowMs: now()))
      }
    }
  }

  /// No first measurement `connectWindowMs` after a direct connect (or a passive link coming up): hunt again.
  private func armConnectWindow() {
    connectWindow?.cancel()
    connectWindow = scheduler.after(Self.connectWindowMs) { [self] in
      connectWindow = nil
      if connected { return }
      trace("no measurement within \(Self.connectWindowMs)ms; state=\(policy.state)")
      closeLink()
      setConnected(false)
      apply(policy.onConnectFailed(nowMs: now()))
    }
  }

  // MARK: hunt

  private func startHunt(_ h: BleReconnectPolicy.Action) {
    guard case .hunt(_, let scanMs, let passive, let lowLatency) = h else { return }
    let c = ensureCentral()
    guard c.poweredOn, c.authorized else {
      trace("hunt cannot scan: powered=\(c.poweredOn) authorized=\(c.authorized)")
      apply(policy.onScanEnded(nowMs: now(), failed: true))
      return
    }
    huntSeen.removeAll()
    guard c.startScan() else {
      trace("hunt scan start failed")
      apply(policy.onScanEnded(nowMs: now(), failed: true))
      return
    }
    huntCounter += 1
    let token = huntCounter
    huntToken = token
    trace("hunt start scanMs=\(scanMs) fast=\(lowLatency) passive=\(id4(passive)) name=\(policy.savedName ?? "-")")
    huntEnd = scheduler.after(scanMs) { [self] in
      huntEnd = nil
      guard huntToken == token else { return }
      trace("hunt scan ended, \(huntSeen.count) HR device(s) seen, no match")
      stopHunt()
      apply(policy.onScanEnded(nowMs: now(), failed: false))
    }
    scheduleHuntTick(token)
    // A strap that kept its identifier comes back on its own; the scan covers one that changed.
    connect(passive, passive: true)
  }

  private func scheduleHuntTick(_ token: Int) {
    huntTick = scheduler.after(Self.huntTickMs) { [self] in
      guard huntToken == token else { return }
      apply(policy.onHuntTick(nowMs: now()))
      if huntToken == token { scheduleHuntTick(token) }
    }
  }

  private func stopHunt() {
    huntEnd?.cancel()
    huntEnd = nil
    huntTick?.cancel()
    huntTick = nil
    guard huntToken != 0 else { return }
    huntToken = 0
    if pairScan == nil { central?.stopScan() }
  }

  // MARK: link

  private func closeLink() {
    if let id = link { central?.cancel(id: id) }
    link = nil
  }

  private func setConnected(_ v: Bool) {
    if !v {
      notificationsOn = false
      silentWatchdog?.cancel()
      silentWatchdog = nil
    } else {
      connectWindow?.cancel()
      connectWindow = nil
      stopHunt()  // a late scan result must not tear down the working link
    }
    if connected == v { return }
    connected = v
    if !v { lastHr = nil }
    listener?.onLink(connected: v)
  }

  /// Notifications are on but nothing arrived: drop and reconnect rather than sit "connected" with no HR.
  private func armWatchdog(_ id: String) {
    silentWatchdog?.cancel()
    silentWatchdog = scheduler.after(Self.silentLinkMs) { [self] in
      silentWatchdog = nil
      if id == link, !connected { setupFailed(id: id, what: "silent link") }
    }
  }

  /// Discovery or subscription failed: retry once, then treat as a drop (close + reconnect).
  private func setupFailed(id: String, what: String) {
    guard id == link else { return }
    trace("setup failed: \(what) retried=\(setupRetried)")
    if !setupRetried {
      setupRetried = true
      _ = scheduler.after(Self.setupRetryMs) { [self] in
        if id == link { central?.beginSetup(id: id) }
      }
    } else {
      closeLink()
      setConnected(false)
      apply(policy.onDisconnected(nowMs: now()))
    }
  }

  // MARK: BleCentralDelegate

  func centralDidChangeState() {
    guard let c = central else { return }
    trace("bluetooth state powered=\(c.poweredOn) authorized=\(c.authorized)")
    if c.poweredOn || !c.authorized {
      let waiting = readyWaiters
      readyWaiters.removeAll()
      for w in waiting { w.fire(c.poweredOn) }
    }
    if !c.poweredOn, link != nil || huntToken != 0 {
      // Bluetooth went off under us: back to the backoff loop, which retries until it is back.
      let wasHunting = policy.state == .hunting
      closeLink()
      setConnected(false)
      listener?.onNoContact()
      stopHunt()
      apply(wasHunting ? policy.onScanEnded(nowMs: now(), failed: true) : policy.onDisconnected(nowMs: now()))
    }
  }

  func central(didDiscover advert: BleAdvert) {
    if let scan = pairScan, !scan.finished {
      if let name = advert.name {
        if seenNames.count >= Self.maxSeenNames, seenNames[advert.id] == nil { seenNames.removeAll() }
        seenNames[advert.id] = name
      }
      if scan.found[advert.id] == nil { scan.order.append(advert.id) }
      let merged = BleAdvert(id: advert.id, name: advert.name ?? scan.found[advert.id]?.name, rssi: advert.rssi)
      scan.found[advert.id] = merged
    }
    guard huntToken != 0 else { return }
    if huntSeen.insert(advert.id).inserted { trace("hunt saw \(id4(advert.id)) name=\(advert.name ?? "-") rssi=\(advert.rssi)") }
    let action = policy.onScanResult(BleReconnectPolicy.Candidate(address: advert.id, name: advert.name, rssi: advert.rssi), nowMs: now())
    if case .connect(let address, _) = action { trace("hunt matched \(id4(address)) by \(String(describing: policy.lastMatch))") }
    apply(action)
  }

  func centralDidConnect(id: String) {
    guard id == link else {
      central?.cancel(id: id)  // a stale connect from a link we already replaced
      return
    }
    trace("link up \(id4(id)) state=\(policy.state)")
    if policy.state == .hunting {
      // The hunt's pending connect came up: stop scanning, set it up.
      policy.onLinkUp()
      stopHunt()
      armConnectWindow()
    }
    central?.beginSetup(id: id)
  }

  func centralNotificationsReady(id: String) {
    guard id == link else { return }
    notificationsOn = true
    armWatchdog(id)
    trace("HR notifications on; waiting for the first measurement")
  }

  func centralSetupFailed(id: String, what: String) { setupFailed(id: id, what: what) }

  func centralDidDisconnect(id: String) {
    guard id == link else { return }
    trace("link down \(id4(id)) state=\(policy.state) wasConnected=\(connected)")
    let hunting = policy.state == .hunting
    if hunting { closeLink() }  // only the pending connect gave up; the hunt's scan carries on
    setConnected(false)
    listener?.onNoContact()
    if !hunting { apply(policy.onDisconnected(nowMs: now())) }
  }

  func central(id: String, didReceive data: Data) {
    guard id == link, let parsed = HeartRateMeasurement.parse(data) else { return }
    let t = now()
    if notificationsOn, !connected {
      silentWatchdog?.cancel()
      silentWatchdog = nil
      policy.onConnected(nowMs: now())
      persistIdentity()
      setConnected(true)
      trace("connected: first measurement bpm=\(parsed.bpm.map(String.init) ?? "no-contact") match=\(String(describing: policy.lastMatch))")
    }
    lastHr = parsed.bpm
    if let bpm = parsed.bpm { listener?.onReading(t: t, bpm: bpm) } else { listener?.onNoContact() }
  }
}
