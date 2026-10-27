import CoreLocation
import Foundation
internal import RunCore

/// The core's clocks: device monotonic millis (the journal's `t`) and wall epoch millis (`w`).
/// Mono must keep counting while the device sleeps (plan §2.6, Android `elapsedRealtime`):
/// `CLOCK_MONOTONIC_RAW` is `mach_continuous_time`; `systemUptime` stops during sleep.
struct RecorderClock {
  var monoMs: () -> Int64
  var wallMs: () -> Int64

  static let system = RecorderClock(
    monoMs: { Int64(clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW) / 1_000_000) },
    wallMs: { Int64(Date().timeIntervalSince1970 * 1000) }
  )
}

enum RecorderHostError: Error {
  case alreadyRecording
  case badJson
}

/// A replay scenario's inputs, as the Kotlin `ReplayScenarios` builds them.
struct ReplayScript {
  struct Fix { let t: Int64; let lat: Double; let lon: Double; let altM: Double?; let accuracyM: Double; let speedMps: Double? }
  let mode: String
  let fixes: [Fix]
  let hr: [(t: Int64, bpm: Int32)]
  let presses: [(atMs: Int64, press: String)]
}

/// iOS recorder host (iOS plan §2, P3, B1): drives the shared Kotlin pipeline (`LiveRecorder`:
/// ticker -> RecorderCore -> journal -> finaliser) from Swift. One serial queue owns the core;
/// fixes arrive from CoreLocation on main and hop onto it; a 1 Hz timer on the same queue ticks.
/// The journal lives under `root/journals/<id>/` and run files under `root/runs/` (root =
/// Application Support, the directory Dart's path_provider also returns).
///
/// Cues (P4): every core `cue` event carries its `CueWords` line and a Free / Trail run adds `km`
/// split lines; both go to [cues] (Android: `RecordingSession.publishCue` / `checkInTick` ->
/// `CuePlayer`). "Paused", "Resumed" and "GPS weak" are said on live runs only, never in a
/// replay, as on Android.
///
/// Kill handling (plan §2 "Kill handling"): the journal is appended and fsync'd by the core as
/// on Android; after a kill the next app open lists it in `orphans()` and Dart's recover dialog
/// finalises or discards it. There is no background relaunch.
final class RecorderHost {
  static let device = "Apple"

  let root: URL
  private let queue = DispatchQueue(label: "app.runsupreme.recorder")
  private let kotlin: LiveRecorder
  private let clock: RecorderClock
  private let send: (RecorderEvent) -> Void
  private let trace: (String) -> Void
  private var timer: DispatchSourceTimer?
  private weak var source: LocationSource?
  private(set) var mode: RecordMode = .free
  private var laps: [LapSummary] = []
  private var lastAccuracy: Double?
  private var fixCount = 0
  private var fixWindowStart: Int64 = 0
  private var autoPaused = false
  private let cues: CueOutput?
  /// Started by [start] (not a replay): the spoken status lines are on.
  private var live = false
  private var gpsWeakStep: Int64?
  /// Strap link and latest fresh reading for the status and tick `hr` fields (set by the BLE bridge).
  var hrLink: () -> (connected: Bool, bpm: Int?) = { (false, nil) }
  /// Called (on the recorder queue) when a run ends, so the strap can be let go.
  var onRunEnded: (() -> Void)?

  init(
    root: URL,
    clock: RecorderClock = .system,
    cues: CueOutput? = nil,
    trace: @escaping (String) -> Void = { _ in },
    send: @escaping (RecorderEvent) -> Void = { _ in }
  ) {
    self.root = root
    self.clock = clock
    self.cues = cues
    self.trace = trace
    self.send = send
    try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    kotlin = LiveRecorder(rootDir: root.path)
  }

  var activeRunId: String? { queue.sync { kotlin.runId } }

  // MARK: Lifecycle

  /// Starts a live run. [spec] is the expanded session (nil for Free, Laps, by-feel intervals);
  /// the core validates it and throws for an unsupported one.
  func start(runId: String, mode: RecordMode, spec: SessionSpec? = nil, units: Units, tz: String = TimeZone.current.identifier) throws {
    try queue.sync {
      guard !kotlin.active else { throw RecorderHostError.alreadyRecording }
      try kotlin.start(
        runId: runId, mode: Self.name(mode), specJson: try spec.map(Self.specJson), units: units == .mi ? "mi" : "km",
        device: Self.device, app: Self.appVersion, tz: tz, t: clock.monoMs(), w: clock.wallMs())
      begin(mode: mode, runId: runId)
      live = true
    }
  }

  /// Starts a run with a replay scenario's mode and session, at times [t] / [w].
  func startScenario(kind: String, runId: String, device: String = RecorderHost.device, app: String = RecorderHost.appVersion, tz: String, t: Int64, w: Int64) throws {
    try queue.sync {
      guard !kotlin.active else { throw RecorderHostError.alreadyRecording }
      try kotlin.startScenario(kind: kind, runId: runId, device: device, app: app, tz: tz, t: t, w: w)
      let script = try scriptLocked(kind: kind)
      begin(mode: Self.recordModes[script.mode] ?? .free, runId: runId)
    }
  }

  private func begin(mode: RecordMode, runId: String) {
    self.mode = mode
    laps = []
    autoPaused = false
    live = false
    gpsWeakStep = nil
    fixCount = 0
    fixWindowStart = 0
    trace("recorder start run=\(runId) mode=\(Self.name(mode))")
    send(StateEvent(state: .recording, runId: runId, phase: .none))
  }

  func feed(t: Int64, w: Int64, lat: Double, lon: Double, altM: Double?, accuracyM: Double, speedMps: Double?) {
    queue.sync { feedLocked(t: t, w: w, lat: lat, lon: lon, altM: altM, accuracyM: accuracyM, speedMps: speedMps) }
  }

  private func feedLocked(t: Int64, w: Int64, lat: Double, lon: Double, altM: Double?, accuracyM: Double, speedMps: Double?) {
    kotlin.onFix(t: t, w: w, lat: lat, lon: lon, altM: altM ?? .nan, accuracyM: accuracyM, speedMps: speedMps ?? .nan)
    lastAccuracy = accuracyM
    fixCount += 1
  }

  func feedHr(t: Int64, bpm: Int32) { queue.sync { kotlin.onHr(t: t, bpm: bpm) } }

  @discardableResult
  func lap(source: LapSource, t: Int64? = nil, w: Int64? = nil) -> String {
    queue.sync { kotlin.lap(source: Self.name(source), t: t ?? clock.monoMs(), w: w ?? clock.wallMs()) }
  }

  @discardableResult
  func startReps(t: Int64? = nil, w: Int64? = nil) -> String {
    queue.sync { kotlin.startReps(t: t ?? clock.monoMs(), w: w ?? clock.wallMs()) }
  }

  func pause(t: Int64? = nil, w: Int64? = nil) {
    queue.sync {
      kotlin.pause(t: t ?? clock.monoMs(), w: w ?? clock.wallMs())
      trace("recorder pause")
      send(StateEvent(state: .paused, runId: kotlin.runId, phase: currentPhase()))
    }
  }

  func resume(t: Int64? = nil, w: Int64? = nil) {
    queue.sync {
      kotlin.resume(t: t ?? clock.monoMs(), w: w ?? clock.wallMs())
      trace("recorder resume")
      send(StateEvent(state: .recording, runId: kotlin.runId, phase: currentPhase()))
    }
  }

  /// Settings > Voice > "Km splits": kept across runs (the core holds it).
  func setKmSplits(_ enabled: Bool) { queue.sync { kotlin.kmSplits = enabled } }

  /// One 1 Hz step at [t] / [w]. Returns `autoStopped` (the session asked to end itself).
  @discardableResult
  func tick(t: Int64? = nil, w: Int64? = nil) -> Bool {
    queue.sync { tickLocked(t: t ?? clock.monoMs(), w: w ?? clock.wallMs()) }
  }

  private func tickLocked(t: Int64, w: Int64) -> Bool {
    let out = Self.object(kotlin.tick(t: t, w: w))
    let status = Self.object(kotlin.statusJson(t: t))
    for event in out["events"] as? [[String: Any]] ?? [] { dispatch(event, status: status) }
    gpsWeak(status)
    sendTick(status)
    if fixWindowStart == 0 { fixWindowStart = t }
    if t - fixWindowStart >= 60_000 {
      trace("fix rate \(fixCount)/min accuracy=\(lastAccuracy.map { String(format: "%.1f", $0) } ?? "none") journalOk=\(status["journalOk"] as? Bool ?? true)")
      fixCount = 0
      fixWindowStart = t
    }
    return out["autoStopped"] as? Bool ?? false
  }

  private func dispatch(_ event: [String: Any], status: [String: Any]) {
    let t = Self.int(event["t"])
    switch event["type"] as? String {
    case "lap":
      let source = Self.lapSources[event["source"] as? String ?? ""] ?? .button
      let lap = LapSummary(
        index: Self.int(event["index"]), tMs: Self.int(status["elapsedMs"]), activeMs: Self.int(status["activeMs"]),
        distanceM: status["distanceM"] as? Double ?? 0, source: source)
      laps.append(lap)
      send(LapEvent(index: lap.index, tMs: lap.tMs, activeMs: lap.activeMs, distanceM: lap.distanceM, source: source))
    case "cue":
      let name = event["kind"] as? String ?? ""
      cues?.cue(kind: name, text: event["text"] as? String)
      if let kind = Self.cueKinds[name] { send(CueEvent(kind: kind, value: event["value"] as? Double)) }
    case "km":
      if let text = event["text"] as? String { cues?.km(text) }
    case "phase":
      send(PhaseEvent(
        phase: Self.phases[event["phase"] as? String ?? ""] ?? .none, repIndex: Self.int(event["repIndex"]),
        phaseDurationMs: Self.int(event["phaseDurationMs"])))
    case "autoPause":
      autoPaused = true
      trace("auto-pause t=\(t)")
      if live { cues?.announce("Paused") }
    case "autoResume":
      autoPaused = false
      trace("auto-resume t=\(t)")
      if live { cues?.announce("Resumed") }
    case "autoStop": trace("auto-stop t=\(t)")
    default: break
    }
  }

  /// A distance rep does not end on its own without GPS (Android W3): said once per rep.
  private func gpsWeak(_ s: [String: Any]) {
    guard live, s["gpsOk"] as? Bool == false, s["stepRemainingM"] is Double,
          let step = s["stepIndex"].flatMap({ $0 is NSNull ? nil : Self.int($0) }), gpsWeakStep != step else { return }
    gpsWeakStep = step
    trace("gps weak in step \(step)")
    cues?.announce("GPS weak")
  }

  private func sendTick(_ s: [String: Any]) {
    let elapsed = Self.int(s["elapsedMs"])
    let distance = s["distanceM"] as? Double ?? 0
    let last = laps.last
    send(TickEvent(
      elapsedMs: elapsed, lapElapsedMs: elapsed - (last?.tMs ?? 0), lapDistanceM: distance - (last?.distanceM ?? 0),
      totalDistanceM: distance, hr: hrLink().bpm.map(Int64.init), gpsAccuracyM: lastAccuracy, state: Self.states[s["state"] as? String ?? ""] ?? .recording,
      phase: Self.phases[s["phase"] as? String ?? ""] ?? .none, repIndex: Self.int(s["repIndex"]),
      phaseRemainingMs: Self.int(s["phaseRemainingMs"]), stepIndex: s["stepIndex"].flatMap { $0 is NSNull ? nil : Self.int($0) },
      stepRemainingMs: s["stepRemainingMs"].flatMap { $0 is NSNull ? nil : Self.int($0) },
      stepRemainingM: s["stepRemainingM"] as? Double, autoPaused: autoPaused))
  }

  private func currentPhase() -> Phase {
    Self.phases[Self.object(kotlin.statusJson(t: clock.monoMs()))["phase"] as? String ?? ""] ?? .none
  }

  /// Ends the run and finalises it; the absolute run file path (nil when idle).
  func stop(t: Int64? = nil, w: Int64? = nil) throws -> String? {
    try queue.sync { try stopLocked(t: t ?? clock.monoMs(), w: w ?? clock.wallMs()) }
  }

  private func stopLocked(t: Int64, w: Int64) throws -> String? {
    stopTimer()
    guard kotlin.active else { return nil }
    let id = kotlin.runId
    let path = try kotlin.stop(t: t, w: w)
    live = false
    // The stop cue ("Run saved") comes out of the core's stop: said, not sent (as Android's stop()).
    let stopped = (try? JSONSerialization.jsonObject(with: Data(kotlin.stopEventsJson.utf8))) as? [[String: Any]] ?? []
    for event in stopped where event["type"] as? String == "cue" {
      cues?.cue(kind: event["kind"] as? String ?? "", text: event["text"] as? String)
    }
    trace("recorder stop run=\(id ?? "-") file=\(path ?? "none")")
    send(StateEvent(state: .idle, runId: id, phase: .none))
    onRunEnded?()
    return path.map { root.appendingPathComponent($0).path }
  }

  /// Drops the live run without finalising, as a kill would (tests; the journal stays).
  func abandon() {
    queue.sync {
      stopTimer()
      kotlin.abandon()
    }
  }

  func status() -> RecorderStatus {
    queue.sync {
      let s = Self.object(kotlin.statusJson(t: clock.monoMs()))
      let state = Self.states[s["state"] as? String ?? ""] ?? .idle
      return RecorderStatus(
        state: state, runId: s["runId"] as? String, mode: state == .idle ? .free : mode, laps: state == .idle ? [] : laps,
        elapsedMs: Self.int(s["elapsedMs"]), lapIndex: Self.int(s["lapIndex"]), gpsFix: s["gpsOk"] as? Bool ?? false,
        hrConnected: hrLink().connected, phase: Self.phases[s["phase"] as? String ?? ""] ?? .none, repIndex: Self.int(s["repIndex"]),
        phaseRemainingMs: Self.int(s["phaseRemainingMs"]),
        stepIndex: s["stepIndex"].flatMap { $0 is NSNull ? nil : Self.int($0) },
        stepRemainingMs: s["stepRemainingMs"].flatMap { $0 is NSNull ? nil : Self.int($0) },
        stepRemainingM: s["stepRemainingM"] as? Double, journalOk: s["journalOk"] as? Bool ?? true,
        pausedAtElapsedMs: s["pausedAtElapsedMs"].flatMap { $0 is NSNull ? nil : Self.int($0) })
    }
  }

  /// Journals a kill left behind (never the live run).
  func orphans() -> [OrphanJournal] {
    queue.sync {
      let rows = (try? JSONSerialization.jsonObject(with: Data(kotlin.orphansJson(nowMs: clock.wallMs()).utf8))) as? [[String: Any]] ?? []
      return rows.map { r in
        OrphanJournal(
          runId: r["runId"] as? String ?? "", lastLineAgeMs: Self.int(r["lastLineAgeMs"]),
          mode: Self.recordModes[r["mode"] as? String ?? ""] ?? .free, readable: r["readable"] as? Bool ?? false,
          newer: r["newer"] as? Bool ?? false, endedPaused: r["endedPaused"] as? Bool ?? false, elapsedMs: Self.int(r["elapsedMs"]))
      }
    }
  }

  /// Journal -> run file (idempotent); the absolute path, nil for nothing / live / corrupt.
  func finalise(runId: String) throws -> String? {
    try queue.sync {
      let path = try kotlin.finalise(runId: runId, nowMs: clock.wallMs(), activeRunId: kotlin.runId)
      trace("finalise run=\(runId) file=\(path ?? "none")")
      return path.map { root.appendingPathComponent($0).path }
    }
  }

  func discardJournal(runId: String) {
    queue.sync {
      kotlin.discardJournal(runId: runId)
      trace("discard journal run=\(runId)")
    }
  }

  // MARK: Live recording (CoreLocation + 1 Hz timer)

  /// Feeds `source`'s fixes into the run and ticks once a second until stop. Call after start.
  func attach(_ source: LocationSource) {
    DispatchQueue.main.async {
      source.addFixListener("recorder") { [weak self] location in self?.onLocation(location) }
      source.start(background: true, owner: "recorder")
    }
    queue.sync {
      self.source = source
      startTimer(interval: .seconds(1)) { [weak self] in self?.liveTick() }
    }
  }

  private func onLocation(_ location: CLLocation) {
    guard location.horizontalAccuracy >= 0 else { return }
    let wall = Int64(location.timestamp.timeIntervalSince1970 * 1000)
    queue.async {
      let now = self.clock.monoMs()
      let age = max(0, self.clock.wallMs() - wall)
      self.feedLocked(
        t: now - min(age, 5_000), w: wall, lat: location.coordinate.latitude, lon: location.coordinate.longitude,
        altM: location.verticalAccuracy >= 0 ? location.altitude : nil, accuracyM: location.horizontalAccuracy,
        speedMps: location.speed >= 0 ? location.speed : nil)
    }
  }

  private func liveTick() {
    guard kotlin.active else { return }
    if tickLocked(t: clock.monoMs(), w: clock.wallMs()) {
      _ = try? stopLocked(t: clock.monoMs(), w: clock.wallMs())
    }
  }

  private func startTimer(interval: DispatchTimeInterval, _ fire: @escaping () -> Void) {
    stopTimer()
    let t = DispatchSource.makeTimerSource(queue: queue)
    t.schedule(deadline: .now() + interval, repeating: interval)
    t.setEventHandler(handler: fire)
    t.resume()
    timer = t
  }

  /// On the queue. Also releases the location source.
  private func stopTimer() {
    timer?.cancel()
    timer = nil
    if let source {
      DispatchQueue.main.async {
        source.removeFixListener("recorder")
        source.stop(owner: "recorder")
      }
      self.source = nil
    }
  }

  // MARK: Replay (contract scenarios through this wiring)

  static let replayT0: Int64 = 1_000_000
  static let replayW0: Int64 = 1_758_672_000_000 // 2025-09-24T00:00:00Z, as ReplayRun

  /// Records scenario [kind] synchronously through this host exactly as the Kotlin `ReplayRun`
  /// does (same header, clocks, input order and presses), so the run file must equal the
  /// contract fixture `replay_<kind>.json`. Returns the run file path.
  func runScenario(kind: String, killAfterFixes: Int? = nil) throws -> String? {
    let script = try self.script(kind: kind)
    let t0 = Self.replayT0, w0 = Self.replayW0
    try startScenario(kind: kind, runId: "replay-\(kind)", device: "contract-fixture", app: "core-jvm-test", tz: "Australia/Sydney", t: t0, w: w0)
    var hrIndex = 0, pressed = 0
    var t = t0, w = w0
    let firstT = script.fixes.first?.t ?? 0
    for (i, f) in script.fixes.enumerated() {
      if let killAfterFixes, i == killAfterFixes { abandon(); return nil }
      t = t0 + f.t
      w = w0 + f.t
      while hrIndex < script.hr.count, script.hr[hrIndex].t <= f.t {
        feedHr(t: t0 + script.hr[hrIndex].t, bpm: script.hr[hrIndex].bpm)
        hrIndex += 1
      }
      feed(t: t, w: w, lat: f.lat, lon: f.lon, altM: f.altM, accuracyM: f.accuracyM, speedMps: f.speedMps)
      if pressed < script.presses.count, f.t - firstT >= script.presses[pressed].atMs {
        switch script.presses[pressed].press {
        case "lap": lap(source: .notification, t: t, w: w)
        case "startReps": startReps(t: t, w: w)
        case "pause": pause(t: t, w: w)
        default: break
        }
        pressed += 1
      }
      if tick(t: t, w: w) { break }
    }
    return try stop(t: t, w: w)
  }

  /// Pigeon `startReplay`: the scenario's fixes on a timer, `speed` seconds of run per second.
  func startTimedReplay(kind: String, runId: String, speed: Double) throws {
    let script = try self.script(kind: kind)
    let t0 = clock.monoMs(), w0 = clock.wallMs()
    try startScenario(kind: kind, runId: runId, tz: TimeZone.current.identifier, t: t0, w: w0)
    var i = 0, pressed = 0
    let interval = DispatchTimeInterval.milliseconds(max(1, Int(1000 / max(speed, 0.1))))
    queue.sync {
      startTimer(interval: interval) { [weak self] in
        guard let self, self.kotlin.active else { return }
        guard i < script.fixes.count else { _ = try? self.stopLocked(t: t0 + (script.fixes.last?.t ?? 0), w: w0 + (script.fixes.last?.t ?? 0)); return }
        let f = script.fixes[i]
        i += 1
        let t = t0 + f.t, w = w0 + f.t
        self.feedLocked(t: t, w: w, lat: f.lat, lon: f.lon, altM: f.altM, accuracyM: f.accuracyM, speedMps: f.speedMps)
        if pressed < script.presses.count, f.t >= script.presses[pressed].atMs {
          let p = script.presses[pressed].press
          pressed += 1
          if p == "lap" { _ = self.kotlin.lap(source: "notification", t: t, w: w) }
          if p == "startReps" { _ = self.kotlin.startReps(t: t, w: w) }
          if p == "pause" { self.kotlin.pause(t: t, w: w) }
        }
        if self.tickLocked(t: t, w: w) { _ = try? self.stopLocked(t: t, w: w) }
      }
    }
  }

  // MARK: Helpers

  /// A finished run file as parsed JSON (the core's gzip reader).
  func readRunFile(runId: String) throws -> [String: Any] {
    try queue.sync { Self.object(try kotlin.readRunFileJson(runId: runId)) }
  }

  func script(kind: String) throws -> ReplayScript { try queue.sync { try scriptLocked(kind: kind) } }

  private func scriptLocked(kind: String) throws -> ReplayScript {
    let o = Self.object(try kotlin.scenarioScriptJson(kind: kind))
    func d(_ v: Any?) -> Double? { v is NSNull ? nil : (v as? NSNumber)?.doubleValue }
    let fixes = (o["fixes"] as? [[Any]] ?? []).map { r in
      ReplayScript.Fix(t: Self.int(r[0]), lat: d(r[1]) ?? 0, lon: d(r[2]) ?? 0, altM: d(r[3]), accuracyM: d(r[4]) ?? 0, speedMps: d(r[5]))
    }
    let hr = (o["hr"] as? [[Any]] ?? []).map { (t: Self.int($0[0]), bpm: Int32(Self.int($0[1]))) }
    let presses = (o["presses"] as? [[Any]] ?? []).map { (atMs: Self.int($0[0]), press: $0[1] as? String ?? "") }
    return ReplayScript(mode: o["mode"] as? String ?? "free", fixes: fixes, hr: hr, presses: presses)
  }

  /// Pigeon session -> the core's `SessionSpec.toJson()` shape (as Android's `SessionSpec.toCore`).
  /// Pigeon's Swift enum cases carry the core's names (`work`, `equalToPreviousWork`, ...).
  static func specJson(_ spec: SessionSpec) throws -> String {
    var m: [String: Any] = [
      "templateId": spec.templateId, "templateVersion": spec.templateVersion, "name": spec.name,
      "warmupSeconds": spec.warmupSeconds.map { $0 as Any } ?? NSNull(),
      "cooldownSeconds": spec.cooldownSeconds.map { $0 as Any } ?? NSNull(),
      "lapLockout": spec.lapLockout, "autoStop": spec.autoStop ?? false, "cueProfile": "\(spec.cueProfile)",
      "steps": spec.steps.map { st in
        ["kind": "\(st.kind)", "target": "\(st.target)", "value": st.value, "style": "\(st.style)", "rep": st.repIndex] as [String: Any]
      },
    ]
    if let lo = spec.hrBandLow, let hi = spec.hrBandHigh { m["hrBand"] = [lo, hi] } else { m["hrBand"] = NSNull() }
    if let spoken = spec.spokenName { m["spokenName"] = spoken }
    return String(decoding: try JSONSerialization.data(withJSONObject: m), as: UTF8.self)
  }

  static var appVersion: String {
    let info = Bundle.main.infoDictionary
    return "ios-\(info?["CFBundleShortVersionString"] as? String ?? "0")+\(info?["CFBundleVersion"] as? String ?? "0")"
  }

  static func object(_ json: String) -> [String: Any] {
    (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any] ?? [:]
  }

  static func int(_ v: Any?) -> Int64 { (v as? NSNumber)?.int64Value ?? 0 }

  static let recordModes: [String: RecordMode] = ["intervals": .intervals, "laps": .laps, "free": .free, "cooper": .cooper, "trail": .trail]
  static let phases: [String: Phase] = ["none": .none, "warmup": .warmup, "work": .work, "recovery": .recovery, "cooldown": .cooldown]
  static let states: [String: RecorderState] = ["idle": .idle, "recording": .recording, "paused": .paused, "finalising": .finalising]
  static let lapSources: [String: LapSource] = ["button": .button, "notification": .notification, "volumeKey": .volumeKey, "auto": .auto]
  static let cueKinds: [String: CueKind] = [
    "halfway": .halfway, "thirtySeconds": .thirtySeconds, "phaseEnd": .phaseEnd, "start": .start, "stop": .stop,
    "distanceToGo": .distanceToGo, "lastRep": .lastRep, "minuteMark": .minuteMark, "countdown": .countdown,
    "projection": .projection, "tenSeconds": .tenSeconds,
  ]

  static func name(_ mode: RecordMode) -> String { recordModes.first { $0.value == mode }?.key ?? "free" }
  static func name(_ source: LapSource) -> String { lapSources.first { $0.value == source }?.key ?? "button" }
}
