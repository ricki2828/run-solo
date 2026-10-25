import AVFoundation
import XCTest
@testable import Runner

/// P4: what the iOS recorder says (the shared core's words, checked against the voice-copy
/// fixture) and how `CuePlayer` handles the audio session, interruptions and route changes.
final class CuePlayerTests: XCTestCase {
  private static let repoRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

  /// `voice_copy.tsv` (`id<TAB>words<TAB>text`), the Kotlin VoiceCopyFixture's checked-in snapshot.
  private func voiceCopy() throws -> [String: String] {
    let url = Self.repoRoot.appendingPathComponent("android/core-jvm/src/test/fixtures/voice/voice_copy.tsv")
    var out: [String: String] = [:]
    for line in try String(contentsOf: url, encoding: .utf8).split(separator: "\n") {
      let f = line.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
      if f.count == 3 { out[String(f[0])] = String(f[2]) }
    }
    XCTAssertGreaterThan(out.count, 50)
    return out
  }

  private func scratchDir() -> URL {
    URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("cue-" + UUID().uuidString, isDirectory: true)
  }

  private static func spec(_ profile: CueProfile = .standard, steps: [SessionStep]) -> SessionSpec {
    SessionSpec(
      templateId: "norwegian-4x4", templateVersion: 1, name: "Norwegian 4x4", warmupSeconds: nil, cooldownSeconds: nil,
      lapLockout: false, cueProfile: profile, hrBandLow: 0.85, hrBandHigh: 0.95, steps: steps)
  }

  private static let fourByFour: SessionSpec = spec(steps: (1...4).flatMap { r -> [SessionStep] in
    let work = SessionStep(kind: .work, target: .time, value: 240, style: .run, repIndex: Int64(r))
    return r < 4 ? [work, SessionStep(kind: .recovery, target: .time, value: 180, style: .jog, repIndex: Int64(r))] : [work]
  })

  private static func recovery(_ style: RecoveryStyle) -> SessionSpec {
    spec(steps: [fourByFour.steps[0], SessionStep(kind: .recovery, target: .time, value: 60, style: style, repIndex: 1)])
  }

  private static let distance = spec(steps: (1...20).map { SessionStep(kind: .work, target: .distance, value: 400, style: .run, repIndex: Int64($0)) })
  private static let cooper = SessionSpec(
    templateId: "cooper-12", templateVersion: 1, name: "12-minute test", warmupSeconds: nil, cooldownSeconds: nil,
    lapLockout: true, cueProfile: .cooper, steps: [SessionStep(kind: .work, target: .time, value: 720, style: .run, repIndex: 1)])

  // MARK: Words (shared core via the Swift bridge) vs the voice-copy fixture

  func testCueWordsThroughTheSwiftBridgeMatchTheVoiceCopyFixture() throws {
    let copy = try voiceCopy()
    let fx = Self.fourByFour
    let short = Self.spec(.short, steps: fx.steps)
    let cases: [(id: String, said: String?)] = try [
      ("cue.start.time-rep", VoiceWords.cue(kind: "start", spec: fx, phase: "work", repIndex: 4, stepIndex: 0)),
      ("cue.start.distance-rep", VoiceWords.cue(kind: "start", spec: Self.distance, phase: "work", repIndex: 20, stepIndex: 0)),
      ("cue.start.short-rep", VoiceWords.cue(kind: "start", spec: short, phase: "work", repIndex: 1, stepIndex: 0)),
      ("cue.start.cooper", VoiceWords.cue(kind: "start", spec: Self.cooper, phase: "work", repIndex: 1, stepIndex: 0)),
      ("cue.start.recover", VoiceWords.cue(kind: "start", spec: fx, phase: "recovery", repIndex: 1, stepIndex: 1)),
      ("cue.start.short-recover", VoiceWords.cue(kind: "start", spec: short, phase: "recovery", repIndex: 1, stepIndex: 1)),
      ("cue.start.walk", VoiceWords.cue(kind: "start", spec: Self.recovery(.walk), phase: "recovery", repIndex: 1, stepIndex: 1)),
      ("cue.start.stand", VoiceWords.cue(kind: "start", spec: Self.recovery(.stand), phase: "recovery", repIndex: 1, stepIndex: 1)),
      ("cue.halfway", VoiceWords.cue(kind: "halfway", spec: fx, phase: "work", repIndex: 1, stepIndex: 0)),
      ("cue.thirty-seconds", VoiceWords.cue(kind: "thirtySeconds", spec: fx, phase: "work", repIndex: 1, stepIndex: 0)),
      ("cue.ten-seconds", VoiceWords.cue(kind: "tenSeconds", spec: fx, phase: "work", repIndex: 1, stepIndex: 0)),
      ("cue.phase-end.cooldown", VoiceWords.cue(kind: "phaseEnd", spec: fx, phase: "cooldown", repIndex: 1, stepIndex: nil)),
      ("cue.phase-end.cooper", VoiceWords.cue(kind: "phaseEnd", spec: Self.cooper, phase: "cooldown", repIndex: 1, stepIndex: nil)),
      ("cue.phase-end.cooldown-over", VoiceWords.cue(kind: "phaseEnd", value: 1.0, spec: fx, phase: "cooldown", repIndex: 1, stepIndex: nil)),
      ("cue.stop", VoiceWords.cue(kind: "stop", spec: fx, phase: "none", repIndex: 1, stepIndex: nil)),
      ("cue.distance-to-go", VoiceWords.cue(kind: "distanceToGo", spec: Self.distance, phase: "work", repIndex: 1, stepIndex: 0)),
      ("cue.minute-mark.1", VoiceWords.cue(kind: "minuteMark", value: 1, spec: Self.cooper, phase: "work", repIndex: 1, stepIndex: 0)),
      ("cue.minute-mark.11", VoiceWords.cue(kind: "minuteMark", value: 11, spec: Self.cooper, phase: "work", repIndex: 1, stepIndex: 0)),
      ("km.split", VoiceWords.kmSplit(km: 3, activeMs: 920_000, splitMs: 307_000)),
      ("km.split.whole-minutes", VoiceWords.kmSplit(km: 2, activeMs: 600_000, splitMs: 300_000)),
      ("km.split.over-an-hour", VoiceWords.kmSplit(km: 12, activeMs: 3_845_000, splitMs: 320_000)),
      ("km.split.longest", VoiceWords.kmSplit(km: 10, activeMs: 7_199_000, splitMs: 599_000)),
      ("km.split.no-pace", VoiceWords.kmSplit(km: 4, activeMs: 1_220_000, splitMs: nil)),
    ]
    for c in cases {
      let want = try XCTUnwrap(copy[c.id], "fixture has no \(c.id)")
      XCTAssertEqual(c.said, want, c.id)
    }
    // Silent by design: the last-rep cue (the start line says it) and the countdown (three beeps).
    XCTAssertNil(try VoiceWords.cue(kind: "lastRep", spec: fx, phase: "work", repIndex: 4, stepIndex: 6))
    XCTAssertNil(try VoiceWords.cue(kind: "countdown", spec: fx, phase: "work", repIndex: 1, stepIndex: 0))
    XCTAssertEqual((0...3).reversed().map { VoiceWords.countdownBeat($0) }, ["Three", "Two", "One", "Go"])
    XCTAssertNil(VoiceWords.countdownBeat(4))
  }

  // MARK: Words through the recorder wiring

  private final class RecordingCues: CueOutput {
    var said: [(kind: String, text: String?)] = []
    func cue(kind: String, text: String?) { said.append((kind, text)) }
    func km(_ text: String) { said.append(("km", text)) }
    func announce(_ text: String) { said.append(("announce", text)) }
    var texts: [String] { said.compactMap { $0.text } }
  }

  func testFourByFourReplaySpeaksTheCoreLinesInOrder() throws {
    let copy = try voiceCopy()
    let cues = RecordingCues()
    let host = RecorderHost(root: scratchDir(), cues: cues)
    XCTAssertNotNil(try host.runScenario(kind: "4x4"))
    XCTAssertEqual(cues.said.first?.kind, "start")
    XCTAssertEqual(cues.said.first?.text, "Go. Rep 1")
    XCTAssertEqual(cues.said.last?.kind, "stop")
    XCTAssertEqual(cues.said.last?.text, copy["cue.stop"])
    for id in ["cue.start.recover", "cue.halfway", "cue.thirty-seconds", "cue.ten-seconds", "cue.phase-end.cooldown"] {
      XCTAssertTrue(cues.texts.contains(try XCTUnwrap(copy[id])), id)
    }
    // A countdown before every timed part's end, as three beeps (no words).
    let countdowns = cues.said.filter { $0.kind == "countdown" }
    XCTAssertGreaterThanOrEqual(countdowns.count, 3)
    XCTAssertTrue(countdowns.allSatisfy { $0.text == nil })
    XCTAssertFalse(cues.said.contains { $0.kind == "km" || $0.kind == "announce" }) // intervals: no km lines; replay: no status lines
    for text in cues.texts {
      XCTAssertLessThanOrEqual(text.split(separator: " ").count, 16, text)
      XCTAssertFalse(text.contains("\u{2014}"), text)
    }
  }

  func testCooperReplaySaysTheMinuteMarkAndTheEnd() throws {
    let copy = try voiceCopy()
    let cues = RecordingCues()
    XCTAssertNotNil(try RecorderHost(root: scratchDir(), cues: cues).runScenario(kind: "cooper"))
    XCTAssertEqual(cues.said.first?.text, copy["cue.start.cooper"])
    XCTAssertTrue(cues.texts.contains(try XCTUnwrap(copy["cue.minute-mark.1"])))
    XCTAssertTrue(cues.texts.contains(try XCTUnwrap(copy["cue.phase-end.cooper"])))
  }

  /// A Free run's km splits come from the shared `LiveCoach` (no live context), word for word as Android.
  func testFreeRunReplaySaysEachKmSplitAndTheSettingSilencesThem() throws {
    let cues = RecordingCues()
    XCTAssertNotNil(try RecorderHost(root: scratchDir(), cues: cues).runScenario(kind: "t4-free-5k-fast"))
    XCTAssertEqual(cues.said.filter { $0.kind == "km" }.compactMap { $0.text }, [
      "1 k, 3 minutes 48, pace 3:48.", "2 k, 8 minutes 55, pace 5:08.", "3 k, 14 minutes 3, pace 5:08.",
      "4 k, 19 minutes 11, pace 5:08.", "5 k, 24 minutes 20, pace 5:08.",
    ])
    XCTAssertEqual(cues.said.last?.text, "Run saved")

    let quiet = RecordingCues()
    let host = RecorderHost(root: scratchDir(), cues: quiet)
    host.setKmSplits(false)
    XCTAssertNotNil(try host.runScenario(kind: "t4-free-5k-fast"))
    XCTAssertFalse(quiet.said.contains { $0.kind == "km" })
  }

  /// A live Free run (not a replay) says its km and, standing still, "Paused" then "Resumed".
  func testLiveFreeRunSaysKmAndAutoPause() throws {
    var t: Int64 = 5_000_000, w: Int64 = 1_760_000_000_000
    let cues = RecordingCues()
    let host = RecorderHost(root: scratchDir(), clock: RecorderClock(monoMs: { t }, wallMs: { w }), cues: cues)
    try host.start(runId: "live-cues", mode: .free, units: .km, tz: "Australia/Sydney")
    var lat = -33.86
    func run(seconds: Int, mps: Double) {
      for _ in 0..<seconds {
        t += 1_000
        w += 1_000
        lat += mps / 111_320
        host.feed(t: t, w: w, lat: lat, lon: 151.2, altM: 20, accuracyM: 5, speedMps: mps)
        host.tick()
      }
    }
    run(seconds: 360, mps: 3)
    run(seconds: 60, mps: 0)
    run(seconds: 60, mps: 3)
    XCTAssertNotNil(try host.stop())
    XCTAssertTrue(cues.said.contains { $0.kind == "km" && $0.text?.hasPrefix("1 k, ") == true }, "\(cues.texts)")
    let announced = cues.said.filter { $0.kind == "announce" }.compactMap { $0.text }
    XCTAssertEqual(announced.first, "Paused", "\(announced)")
    XCTAssertTrue(announced.contains("Resumed"), "\(announced)")
    XCTAssertEqual(cues.said.last?.text, "Run saved")
  }

  // MARK: CuePlayer: session, vibration, interruptions, routes

  private final class FakeAudio: CueAudio {
    var onSpeechDone: ((Int) -> Void)?
    var spoken: [(text: String, id: Int)] = []
    var activations = 0, deactivations = 0, stops = 0, vibrations = 0, configures = 0, resets = 0
    var beeps: [Bool] = []
    var failActivate = false
    /// The next N deactivations throw (`isBusy`).
    var failDeactivations = 0
    var deactivateAttempts = 0
    func configure() throws { configures += 1 }
    func activate() throws {
      if failActivate { throw NSError(domain: "AVAudioSession", code: 560_557_684) }
      activations += 1
    }
    func deactivate() throws {
      deactivateAttempts += 1
      if failDeactivations > 0 {
        failDeactivations -= 1
        throw NSError(domain: "AVAudioSession", code: 560_030_580) // isBusy
      }
      deactivations += 1
    }
    func reset() { resets += 1 }
    func speak(_ text: String, id: Int) { spoken.append((text, id)) }
    func stopSpeaking() { stops += 1 }
    func beep(high: Bool) { beeps.append(high) }
    func vibrate() { vibrations += 1 }
    func finish(_ i: Int) { onSpeechDone?(spoken[i].id) }
    var texts: [String] { spoken.map { $0.text } }
  }

  /// `asyncAfter` by hand: [fire] runs everything due, including what that schedules.
  private final class Later {
    var queue: [(TimeInterval, () -> Void)] = []
    func schedule(_ delay: TimeInterval, _ f: @escaping () -> Void) { queue.append((delay, f)) }
    func fire() {
      while !queue.isEmpty {
        queue.sort { $0.0 < $1.0 }
        queue.removeFirst().1()
      }
    }
  }

  private func player(_ audio: FakeAudio, _ center: NotificationCenter, _ later: Later, log: @escaping (String) -> Void = { _ in }) -> CuePlayer {
    CuePlayer(audio: audio, center: center, run: { $0() }, after: { later.schedule($0, $1) }, log: log)
  }

  func testACueVibratesSpeaksAndReleasesTheSessionWhenDone() {
    let audio = FakeAudio(), later = Later()
    let p = player(audio, NotificationCenter(), later)
    p.cue(kind: "halfway", text: "Halfway")
    p.km("1 k, 5 minutes, pace 5:00.")
    XCTAssertEqual(audio.texts, ["Halfway", "1 k, 5 minutes, pace 5:00."])
    XCTAssertEqual(audio.configures, 1)
    XCTAssertEqual(audio.activations, 1) // one activation for back-to-back lines
    XCTAssertEqual(audio.vibrations, 2)
    audio.finish(0)
    XCTAssertEqual(audio.deactivations, 0) // the km line is still being said
    audio.finish(1)
    XCTAssertEqual(audio.deactivations, 1) // other audio comes back up
    audio.finish(1)
    XCTAssertEqual(audio.deactivations, 1) // a duplicate callback changes nothing
    p.cue(kind: "start", text: "Go. Rep 1")
    XCTAssertEqual(audio.activations, 2)
    later.fire()
    XCTAssertEqual(audio.vibrations, 4) // start: a double buzz
  }

  func testCuesOffStillVibrateButSayNothing() {
    let audio = FakeAudio(), later = Later()
    let p = player(audio, NotificationCenter(), later)
    p.enabled = false
    p.cue(kind: "halfway", text: "Halfway")
    p.km("1 k, 5 minutes.")
    p.announce("Paused")
    p.cue(kind: "countdown", text: nil)
    later.fire()
    XCTAssertTrue(audio.spoken.isEmpty)
    XCTAssertTrue(audio.beeps.isEmpty)
    XCTAssertEqual(audio.activations, 0)
    XCTAssertEqual(audio.vibrations, 3)
  }

  func testCountdownIsThreeBeepsTheLastHighThenTheSessionIsReleased() {
    let audio = FakeAudio(), later = Later()
    let p = player(audio, NotificationCenter(), later)
    p.cue(kind: "countdown", text: nil)
    XCTAssertEqual(audio.activations, 1)
    XCTAssertTrue(audio.beeps.isEmpty)
    later.fire()
    XCTAssertEqual(audio.beeps, [false, false, true])
    XCTAssertTrue(audio.spoken.isEmpty)
    XCTAssertEqual(p.inFlight, 0)
    XCTAssertEqual(audio.deactivations, 1)
  }

  private func post(_ center: NotificationCenter, _ name: Notification.Name, _ info: [String: Any]) {
    center.post(name: name, object: nil, userInfo: info)
  }

  /// A call: what is queued is dropped; while the call holds the audio the session refuses to
  /// activate and cues are dropped (the buzz still comes); nothing waits for an `.ended`.
  func testInterruptionDropsTheQueueAndDoesNotLatchWithoutAnEnd() {
    let audio = FakeAudio(), later = Later(), center = NotificationCenter()
    var logged: [String] = []
    let p = player(audio, center, later) { logged.append($0) }
    p.cue(kind: "halfway", text: "Halfway")
    p.cue(kind: "countdown", text: nil)
    post(center, AVAudioSession.interruptionNotification, [AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.began.rawValue])
    XCTAssertEqual(audio.stops, 1)
    XCTAssertEqual(p.inFlight, 0)
    XCTAssertEqual(audio.deactivateAttempts, 0) // the system already deactivated it
    later.fire()
    XCTAssertTrue(audio.beeps.isEmpty) // the countdown was dropped with the queue
    audio.finish(0) // the cancelled line's late callback
    audio.failActivate = true // the call holds the audio
    p.cue(kind: "thirtySeconds", text: "Thirty seconds")
    XCTAssertEqual(audio.texts, ["Halfway"])
    XCTAssertEqual(audio.vibrations, 3)
    XCTAssertTrue(logged.contains { $0.hasPrefix("cue dropped (no audio session): Thirty seconds") }, "\(logged)")
    // The call ended but no `.ended` arrived (e.g. the app was suspended): the next cue speaks.
    audio.failActivate = false
    p.cue(kind: "tenSeconds", text: "Ten seconds")
    XCTAssertEqual(audio.texts, ["Halfway", "Ten seconds"])
    XCTAssertEqual(audio.activations, 2)
    post(center, AVAudioSession.interruptionNotification, [
      AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.ended.rawValue,
      AVAudioSessionInterruptionOptionKey: AVAudioSession.InterruptionOptions.shouldResume.rawValue,
    ])
    XCTAssertTrue(logged.contains("audio interruption began"))
    XCTAssertTrue(logged.contains("audio interruption ended shouldResume=true"))
  }

  /// `setActive(false)` refused (isBusy): logged and retried so other audio is not left ducked;
  /// a retry is skipped when a new line has started meanwhile.
  func testFailedDeactivateIsLoggedAndRetried() {
    let audio = FakeAudio(), later = Later()
    var logged: [String] = []
    let p = player(audio, NotificationCenter(), later) { logged.append($0) }
    audio.failDeactivations = 2
    p.cue(kind: "stop", text: "Run saved")
    audio.finish(0)
    XCTAssertEqual(audio.deactivateAttempts, 1)
    XCTAssertEqual(audio.deactivations, 0)
    XCTAssertEqual(later.queue.first?.0, CuePlayer.deactivateRetryDelay)
    later.fire()
    XCTAssertEqual(audio.deactivateAttempts, 3)
    XCTAssertEqual(audio.deactivations, 1)
    XCTAssertEqual(p.deactivateFailures, 2)
    XCTAssertEqual(logged.filter { $0.hasPrefix("audio deactivate failed") }.count, 2)

    audio.failDeactivations = 5
    p.cue(kind: "halfway", text: "Halfway")
    audio.finish(1)
    p.cue(kind: "halfway", text: "Halfway") // a new line before the retry: it holds the session
    later.fire()
    XCTAssertEqual(audio.deactivateAttempts, 4)
    audio.failDeactivations = 1
    audio.finish(2)
    later.fire()
    XCTAssertEqual(audio.deactivateAttempts, 6) // that release failed once, then its retry went through
    XCTAssertEqual(audio.deactivations, 2)
  }

  func testHeadphonesUnpluggedStopTheLineBeingSaidAndLaterCuesStillSpeak() {
    let audio = FakeAudio(), later = Later(), center = NotificationCenter()
    let p = player(audio, center, later)
    p.cue(kind: "halfway", text: "Halfway")
    post(center, AVAudioSession.routeChangeNotification, [AVAudioSessionRouteChangeReasonKey: AVAudioSession.RouteChangeReason.newDeviceAvailable.rawValue])
    XCTAssertEqual(audio.stops, 0)
    post(center, AVAudioSession.routeChangeNotification, [AVAudioSessionRouteChangeReasonKey: AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue])
    XCTAssertEqual(audio.stops, 1)
    XCTAssertEqual(audio.deactivations, 1)
    XCTAssertEqual(p.inFlight, 0)
    p.cue(kind: "thirtySeconds", text: "Thirty seconds")
    XCTAssertEqual(audio.texts, ["Halfway", "Thirty seconds"])
    post(center, AVAudioSession.routeChangeNotification, [AVAudioSessionRouteChangeReasonKey: AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue])
    XCTAssertEqual(audio.stops, 2)
  }

  func testMediaServicesResetReconfiguresOnTheNextCue() {
    let audio = FakeAudio(), later = Later(), center = NotificationCenter()
    let p = player(audio, center, later)
    p.cue(kind: "halfway", text: "Halfway")
    post(center, AVAudioSession.mediaServicesWereResetNotification, [:])
    XCTAssertEqual(p.inFlight, 0)
    XCTAssertEqual(audio.resets, 1) // synthesizer and players rebuilt
    p.cue(kind: "halfway", text: "Halfway")
    XCTAssertEqual(audio.configures, 2)
    XCTAssertEqual(audio.activations, 2)
  }

  func testRefusedSessionDropsTheLineAndLogsIt() {
    let audio = FakeAudio(), later = Later()
    var logged: [String] = []
    let p = player(audio, NotificationCenter(), later) { logged.append($0) }
    audio.failActivate = true
    p.cue(kind: "halfway", text: "Halfway")
    XCTAssertTrue(audio.spoken.isEmpty)
    XCTAssertEqual(audio.vibrations, 1)
    XCTAssertTrue(logged.contains { $0.hasPrefix("cue dropped (no audio session)") }, "\(logged)")
    audio.failActivate = false
    p.cue(kind: "halfway", text: "Halfway")
    XCTAssertEqual(audio.texts, ["Halfway"])
  }

  /// The Ready countdown: each beat cuts off the last without releasing the session between
  /// beats (no music pumping), and the cut line's late callback does not release it under the new one.
  func testCountdownBeatCutsOffThePreviousBeat() {
    let audio = FakeAudio(), later = Later()
    let p = player(audio, NotificationCenter(), later)
    p.speakNow("Three")
    p.speakNow("Two")
    XCTAssertEqual(audio.texts, ["Three", "Two"])
    XCTAssertEqual(audio.stops, 1)
    XCTAssertEqual(audio.activations, 1)
    XCTAssertEqual(audio.deactivateAttempts, 0)
    audio.finish(0) // "Three" reports cancelled after "Two" started
    XCTAssertEqual(p.inFlight, 1)
    XCTAssertEqual(audio.deactivations, 0)
    audio.finish(1)
    XCTAssertEqual(audio.deactivations, 1)
    p.speakNow("Go")
    p.stopSpeaking()
    XCTAssertEqual(audio.stops, 2)
    XCTAssertEqual(p.inFlight, 0)
    XCTAssertEqual(audio.deactivations, 2)
  }

  func testBeepIsAValidPcmWav() {
    let d = SystemCueAudio.wav(hz: 880)
    XCTAssertEqual(d.count, 44 + 2 * 8_820)
    XCTAssertEqual(String(decoding: d.prefix(4), as: UTF8.self), "RIFF")
    XCTAssertEqual(String(decoding: d[8..<16], as: UTF8.self), "WAVEfmt ")
    XCTAssertNotNil(try? AVAudioPlayer(data: d))
  }
}
