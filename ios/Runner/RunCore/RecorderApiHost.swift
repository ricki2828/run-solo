import Foundation

/// Pigeon `RecorderApi` on iOS (P3): the recorder calls go to `RecorderHost`, the cue settings and
/// the Ready countdown voice to `CuePlayer` (P4); the coaching and Phase 2 settings stay safe
/// no-ops (spoken summaries and live coach P11, strap P5).
final class RecorderApiHost: RecorderApi {
  let host: RecorderHost
  let source: LocationSource
  /// Pre-start GPS readiness (P2), sharing `source` with the recorder.
  var probe: GpsProbe?
  private let log: DiagnosticsLog
  private let cues: CuePlayer?
  /// The paired heart rate strap (nil in tests that do not need one).
  private let strap: BleHrClient?
  private let bridge: RecorderStrapBridge?

  init(host: RecorderHost, source: LocationSource, cues: CuePlayer? = nil, strap: BleHrClient? = nil, log: DiagnosticsLog = .shared) {
    self.host = host
    self.source = source
    self.cues = cues
    self.strap = strap
    self.log = log
    bridge = strap.map { _ in RecorderStrapBridge(host: host) }
    if let strap, let bridge {
      host.hrLink = { bridge.snapshot }
      host.onRunEnded = { DispatchQueue.main.async { strap.disconnect() } }
      DispatchQueue.main.async { strap.listener = bridge }
    }
  }

  func start(mode: RecordMode, spec: SessionSpec?, units: Units, liveContext: LiveContext?, route: FollowRoute?) throws -> StartResult {
    guard host.activeRunId == nil else { return StartResult(runId: nil, error: .alreadyRunning) }
    guard source.authorized else { return StartResult(runId: nil, error: .noFinePermission) }
    let runId = UUID().uuidString.lowercased()
    do {
      try host.start(runId: runId, mode: mode, spec: spec, units: units)
    } catch {
      log.log("recorder", "start failed: \(error)")
      return StartResult(runId: nil, error: spec == nil ? .startFailed : .unsupportedSession)
    }
    host.attach(source)
    DispatchQueue.main.async { self.strap?.connectIfPaired() }
    return StartResult(runId: runId, error: nil)
  }

  func startReplay(mode: RecordMode, spec: SessionSpec?, units: Units, replay: ReplayConfig) throws -> StartResult {
    guard host.activeRunId == nil else { return StartResult(runId: nil, error: .alreadyRunning) }
    let runId = UUID().uuidString.lowercased()
    do {
      try host.startTimedReplay(kind: replay.fixture, runId: runId, speed: replay.speed)
    } catch {
      log.log("recorder", "replay \(replay.fixture) failed: \(error)")
      return StartResult(runId: nil, error: .replayUnavailable)
    }
    return StartResult(runId: runId, error: nil)
  }

  /// Resuming a killed run in place is not wired on iOS yet: Dart's dialog finalises instead.
  func resumeRecovered(runId: String) throws -> StartResult { StartResult(runId: nil, error: .resumeFailed) }
  func pause() throws { host.pause() }
  func resume() throws { host.resume() }
  func lap(source: LapSource) throws { host.lap(source: source) }
  func startReps() throws { host.startReps() }
  /// Mid-run coach prompts are Android only for now (the live coach is, too).
  func answerPrompt(promptId: Int64, optionIndex: Int64) throws {}
  func stop() throws -> String? { try host.stop() }
  func status() throws -> RecorderStatus { host.status() }
  func recover() throws -> [OrphanJournal] {
    let orphans = host.orphans()
    if !orphans.isEmpty { log.log("recorder", "recover found \(orphans.map(\.runId))") }
    return orphans
  }
  func finalise(runId: String) throws -> String? { try host.finalise(runId: runId) }
  func discardJournal(runId: String) throws { host.discardJournal(runId: runId) }

  /// Stops the live run and deletes it instead of keeping a run file.
  func discardRun() throws -> Bool {
    guard let path = try host.stop() else { return false }
    try? FileManager.default.removeItem(atPath: path)
    log.log("recorder", "discarded run file \(path)")
    return true
  }

  func setCues(enabled: Bool) throws { cues?.enabled = enabled }
  /// The probe runs while Start/Ready is on screen: that is also when the saved strap is wanted, so GO finds it connected.
  func startGpsProbe() throws {
    DispatchQueue.main.async {
      self.probe?.start()
      self.strap?.startScreenWants()
    }
  }
  func stopGpsProbe() throws {
    DispatchQueue.main.async {
      self.probe?.stop()
      self.strap?.startScreenReleases()
    }
  }
  func setKmSplits(enabled: Bool) throws { host.setKmSplits(enabled) }
  func setSpokenSummary(enabled: Bool) throws {}
  func setVoiceCoach(config: VoiceCoachConfig) throws {}
  func setCheckIn(metrics: [String], zoneBottomsBpm: [Double]?) throws {}
  func setCoachSlowdown(slowdown: Double?) throws {}
  func speakRunSummary(distanceM: Double, timeMs: Int64, climbM: Double?, verdict: String?, units: Units, includePace: Bool) throws {}
  /// The synthesizer is created with the player: nothing to warm up.
  func prepareCountdownVoice() throws {}
  func speakCountdownBeat(beat: Int64) throws {
    if let text = VoiceWords.countdownBeat(Int(beat)) { cues?.speakNow(text) }
  }
  func stopCountdownVoice() throws { cues?.stopSpeaking() }
  func setAutoPause(enabled: Bool) throws {}
  func muteTips() throws {}
  func setVolumeKeyLaps(enabled: Bool) throws {}
  func routeSince(fromIndex: Int64) throws -> [Double] { [] }
  func followedRoute() throws -> FollowRoute? { nil }

  /// Run files in `runs/` by id -> absolute path.
  func listRunFiles() throws -> [String: String] {
    let dir = host.root.appendingPathComponent("runs", isDirectory: true)
    let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
    var out: [String: String] = [:]
    for name in names where name.hasPrefix("run-") && name.hasSuffix(".json.gz") {
      out[String(name.dropFirst(4).dropLast(8))] = dir.appendingPathComponent(name).path
    }
    return out
  }

  /// iOS has no ApplicationExitInfo (plan §2.4): always `other`; MetricKit lands in the diagnostics log.
  func exitDiagnosis(runId: String) throws -> ExitDiagnosis {
    ExitDiagnosis(runId: runId, reason: .other, timestampMs: 0, manufacturer: "Apple")
  }
}
