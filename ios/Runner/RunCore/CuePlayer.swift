import AVFoundation
import AudioToolbox
import Foundation
internal import RunCore

/// Where the recorder sends what it wants said (`CuePlayer`; a recording fake in tests).
protocol CueOutput: AnyObject {
  /// A core cue (`CueKind` name) and its `CueWords` line; nil text = vibrate only (a countdown is three beeps).
  func cue(kind: String, text: String?)
  /// A Free or Trail run's km split line.
  func km(_ text: String)
  /// A line with no vibration of its own ("Paused", "GPS weak").
  func announce(_ text: String)
}

/// The sound and haptics `CuePlayer` drives: the real `SystemCueAudio`, or a fake in tests.
protocol CueAudio: AnyObject {
  /// Called with the `speak` id once that line finished or was cancelled.
  var onSpeechDone: ((Int) -> Void)? { get set }
  func configure() throws
  func activate() throws
  func deactivate() throws
  /// Rebuilds the synthesizer and players after a media services reset.
  func reset()
  func speak(_ text: String, id: Int)
  func stopSpeaking()
  /// One short beep (~200 ms); [high] for the last countdown beat.
  func beep(high: Bool)
  func vibrate()
}

/// Speaks the session cues on iOS (iOS plan §2 "CuePlayer", P4), the counterpart of Android's
/// `CuePlayer.kt`: the words are the shared core's (`CueWords` via `LiveRecorder` events), so
/// both platforms say the same lines.
///
/// - Audio session `.playback` / `.spokenAudio` with `.duckOthers` and
///   `.interruptSpokenAudioAndMixWithOthers`, active only while something is being said, then
///   deactivated with `.notifyOthersOnDeactivation` so music comes back up (Android's transient
///   ducking focus). The `audio` background mode is only exercised while a cue plays.
/// - `AVSpeechSynthesizer` for speech, generated beeps for the countdown, and a vibration on every
///   cue so a pocketed phone still registers (also with cues off, as on Android).
/// - An interruption (a call, Siri) drops what is queued: a cue is only worth saying on time.
///   Nothing is latched on it (an `.ended` is not guaranteed): each later cue tries to activate
///   the session, which the system refuses while the call holds the audio, and that cue is
///   dropped and logged. Headphones unplugged stop the line being said, so it does not carry on
///   out of the speaker; later cues use the speaker.
/// - A failed deactivation (often `isBusy` right after speech stops) is logged and retried, so
///   other apps' audio does not stay ducked.
///
/// Called from the recorder queue; every state change runs on [run] (main by default).
final class CuePlayer: CueOutput {
  private let audio: CueAudio
  private let run: (@escaping () -> Void) -> Void
  private let after: (TimeInterval, @escaping () -> Void) -> Void
  private let log: (String) -> Void
  private var observers: [NSObjectProtocol] = []
  private let center: NotificationCenter

  /// Pigeon `setCues`: off = vibrations only.
  var enabled: Bool {
    get { lock.withLock { _enabled } }
    set { lock.withLock { _enabled = newValue } }
  }
  private var _enabled = true
  private let lock = NSLock()

  // On [run] only.
  private var configured = false
  private var sessionActive = false
  /// Lines and beeps being played, by id: a late callback for one flushed earlier is ignored.
  private var pending = Set<Int>()
  private var nextId = 0
  /// Tests only (read on [run]'s queue).
  var inFlight: Int { pending.count }
  /// Deactivations the system refused this process lifetime (each one is retried). Tests and diagnostics.
  private(set) var deactivateFailures = 0
  static let deactivateRetries = 3
  static let deactivateRetryDelay: TimeInterval = 0.3

  init(
    audio: CueAudio = SystemCueAudio(),
    center: NotificationCenter = .default,
    run: @escaping (@escaping () -> Void) -> Void = { DispatchQueue.main.async(execute: $0) },
    after: @escaping (TimeInterval, @escaping () -> Void) -> Void = { DispatchQueue.main.asyncAfter(deadline: .now() + $0, execute: $1) },
    log: @escaping (String) -> Void = { _ in }
  ) {
    self.audio = audio
    self.center = center
    self.run = run
    self.after = after
    self.log = log
    audio.onSpeechDone = { [weak self] id in self?.run { self?.done(id) } }
    observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: nil) { [weak self] n in
      guard let self, let raw = n.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
            let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
      let options = (n.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt).map(AVAudioSession.InterruptionOptions.init(rawValue:)) ?? []
      self.run { self.interruption(began: type == .began, shouldResume: options.contains(.shouldResume)) }
    })
    observers.append(center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: nil) { [weak self] n in
      guard let self, let raw = n.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
            let reason = AVAudioSession.RouteChangeReason(rawValue: raw) else { return }
      self.run { self.routeChanged(reason) }
    })
    observers.append(center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: nil) { [weak self] _ in
      guard let self else { return }
      self.run { self.mediaServicesReset() }
    })
  }

  deinit { for o in observers { center.removeObserver(o) } }

  // MARK: CueOutput

  func cue(kind: String, text: String?) {
    let on = enabled
    run {
      self.vibrate(kind: kind)
      guard on else { return }
      if kind == "countdown" { return self.countdown() }
      if let text { self.say(text) }
    }
  }

  func km(_ text: String) {
    let on = enabled
    run {
      self.vibrate(kind: "km")
      if on { self.say(text) }
    }
  }

  func announce(_ text: String) {
    guard enabled else { return }
    run { self.say(text) }
  }

  /// The Ready screen's countdown beat: cuts off the previous beat, never queues behind it. The
  /// session stays active between beats, so music is not unducked and re-ducked every second.
  func speakNow(_ text: String) {
    guard enabled else { return }
    run {
      if !self.pending.isEmpty {
        self.pending.removeAll()
        self.audio.stopSpeaking()
      }
      self.say(text)
    }
  }

  /// Stops what is being said and drops what is queued (the Ready screen was left).
  func stopSpeaking() { run { self.flush() } }

  // MARK: Interruptions and routes

  /// A call or Siri took the audio (began), or gave it back (ended). The system already
  /// deactivated the session; nothing missed is said late, and nothing waits for the end.
  func interruption(began: Bool, shouldResume: Bool) {
    if began {
      sessionActive = false
      flush()
      log("audio interruption began")
    } else {
      log("audio interruption ended shouldResume=\(shouldResume)")
    }
  }

  func routeChanged(_ reason: AVAudioSession.RouteChangeReason) {
    log("audio route change reason=\(reason.rawValue)")
    // Headphones out mid-line: stop it rather than finish it out of the speaker.
    if reason == .oldDeviceUnavailable, inFlight > 0 { flush() }
  }

  func mediaServicesReset() {
    log("audio media services reset")
    configured = false
    sessionActive = false
    pending.removeAll()
    audio.reset()
  }

  // MARK: Internals (on run)

  private func say(_ text: String) {
    guard begin() else {
      log("cue dropped (no audio session): \(text)")
      return
    }
    let id = take()
    audio.speak(text, id: id)
  }

  /// Three beeps a second apart, the last one higher (Android: ToneGenerator PROP_BEEP / BEEP2).
  private func countdown() {
    guard begin() else { return }
    for i in 0..<3 {
      let id = take()
      after(TimeInterval(i)) { [weak self] in
        guard let self else { return }
        self.run {
          guard self.pending.contains(id) else { return } // flushed meanwhile
          self.audio.beep(high: i == 2)
          self.after(0.25) { [weak self] in self?.run { self?.done(id) } }
        }
      }
    }
  }

  /// Configures and activates the session if needed; false when the system refused it.
  private func begin() -> Bool {
    do {
      if !configured {
        try audio.configure()
        configured = true
      }
      if !sessionActive {
        try audio.activate()
        sessionActive = true
      }
      return true
    } catch {
      log("audio session failed: \(error)")
      return false
    }
  }

  private func take() -> Int {
    nextId += 1
    pending.insert(nextId)
    return nextId
  }

  private func done(_ id: Int) {
    guard pending.remove(id) != nil else { return }
    if pending.isEmpty { end() }
  }

  private func flush() {
    let speaking = !pending.isEmpty
    pending.removeAll()
    if speaking { audio.stopSpeaking() }
    end()
  }

  private func end() {
    guard sessionActive else { return }
    sessionActive = false
    release(attempt: 0)
  }

  /// Deactivates with notifyOthers; a refusal is logged and retried while nothing new started.
  private func release(attempt: Int) {
    do {
      try audio.deactivate()
    } catch {
      deactivateFailures += 1
      log("audio deactivate failed (attempt \(attempt + 1), total \(deactivateFailures)): \(error)")
      guard attempt + 1 < Self.deactivateRetries else { return }
      after(Self.deactivateRetryDelay) { [weak self] in
        self?.run {
          guard let self, self.pending.isEmpty, !self.sessionActive else { return }
          self.release(attempt: attempt + 1)
        }
      }
    }
  }

  /// A double buzz for a phase start or end, one for anything else (Android's waveforms).
  private func vibrate(kind: String) {
    audio.vibrate()
    if kind == "start" || kind == "phaseEnd" {
      after(0.5) { [weak self] in self?.run { self?.audio.vibrate() } }
    }
  }
}

/// The real audio: the shared `AVAudioSession`, one `AVSpeechSynthesizer`, generated beeps, and
/// `kSystemSoundID_Vibrate` (works in the background, unlike `UIImpactFeedbackGenerator`).
final class SystemCueAudio: NSObject, CueAudio, AVSpeechSynthesizerDelegate {
  var onSpeechDone: ((Int) -> Void)?
  private var synth = AVSpeechSynthesizer()
  private var ids: [ObjectIdentifier: Int] = [:]
  private var players: [AVAudioPlayer] = []
  private static let low = SystemCueAudio.wav(hz: 880)
  private static let high = SystemCueAudio.wav(hz: 1_320)

  override init() {
    super.init()
    synth.delegate = self
    synth.usesApplicationAudioSession = true
  }

  /// After a media services reset Apple says to recreate audio objects. On main.
  func reset() {
    synth.delegate = nil
    synth = AVSpeechSynthesizer()
    synth.delegate = self
    synth.usesApplicationAudioSession = true
    ids.removeAll()
    players.removeAll()
  }

  /// The core's lines are English: an English voice for the device's region, else en-US.
  private static func voice() -> AVSpeechSynthesisVoice? {
    let region = Locale.current.region?.identifier ?? "US"
    return AVSpeechSynthesisVoice(language: "en-\(region)") ?? AVSpeechSynthesisVoice(language: "en-US")
  }

  func configure() throws {
    try AVAudioSession.sharedInstance().setCategory(
      .playback, mode: .spokenAudio, options: [.duckOthers, .interruptSpokenAudioAndMixWithOthers])
  }

  func activate() throws { try AVAudioSession.sharedInstance().setActive(true) }

  func deactivate() throws { try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation) }

  func speak(_ text: String, id: Int) {
    let u = AVSpeechUtterance(string: text)
    u.voice = Self.voice()
    ids[ObjectIdentifier(u)] = id
    synth.speak(u)
  }

  func stopSpeaking() {
    synth.stopSpeaking(at: .immediate)
    ids.removeAll()
    players.forEach { $0.stop() }
    players.removeAll()
  }

  func beep(high: Bool) {
    guard let p = try? AVAudioPlayer(data: high ? Self.high : Self.low) else { return }
    players.removeAll { !$0.isPlaying }
    players.append(p)
    p.play()
  }

  func vibrate() { AudioServicesPlaySystemSound(kSystemSoundID_Vibrate) }

  func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) { finished(utterance) }
  func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) { finished(utterance) }

  /// `ids` is only touched on main; the delegate's thread is not documented.
  private func finished(_ u: AVSpeechUtterance) {
    DispatchQueue.main.async { // u is kept alive by the closure, so its identifier is not reused meanwhile
      guard let id = self.ids.removeValue(forKey: ObjectIdentifier(u)) else { return }
      self.onSpeechDone?(id)
    }
  }

  /// A 200 ms sine beep as 16-bit mono PCM WAV, with 10 ms fades so it does not click.
  static func wav(hz: Double, ms: Int = 200, rate: Int = 44_100) -> Data {
    let n = rate * ms / 1_000
    let fade = rate / 100
    var pcm = Data(capacity: n * 2)
    for i in 0..<n {
      let env = min(1.0, Double(min(i, n - 1 - i)) / Double(fade))
      let v = Int16(sin(2 * .pi * hz * Double(i) / Double(rate)) * env * 0.6 * Double(Int16.max))
      withUnsafeBytes(of: v.littleEndian) { pcm.append(contentsOf: $0) }
    }
    var d = Data()
    func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
    func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
    d.append(contentsOf: Array("RIFF".utf8)); u32(UInt32(36 + pcm.count))
    d.append(contentsOf: Array("WAVEfmt ".utf8)); u32(16); u16(1); u16(1)
    u32(UInt32(rate)); u32(UInt32(rate * 2)); u16(2); u16(16)
    d.append(contentsOf: Array("data".utf8)); u32(UInt32(pcm.count))
    d.append(pcm)
    return d
  }
}

/// The shared core's words for Swift callers that are not driven by a `LiveRecorder` event
/// (the Ready countdown) and for the voice-copy XCTest.
enum VoiceWords {
  /// `CueWords.text` for [kind] (`CueKind` name) with the session as Pigeon gives it.
  static func cue(kind: String, value: Double? = nil, spec: SessionSpec?, phase: String, repIndex: Int, stepIndex: Int?, index: Int? = nil) throws -> String? {
    try VoiceText.shared.cue(
      kind: kind, value: value ?? .nan, specJson: try spec.map(RecorderHost.specJson), phase: phase,
      repIndex: Int32(repIndex), stepIndex: Int32(stepIndex ?? -1), index: Int32(index ?? -1))
  }

  static func kmSplit(km: Int, activeMs: Int64, splitMs: Int64?) -> String {
    VoiceText.shared.kmSplit(km: Int32(km), activeMs: activeMs, splitMs: splitMs ?? -1)
  }

  static func countdownBeat(_ beat: Int) -> String? { VoiceText.shared.countdownBeat(beat: Int32(beat)) }
}
