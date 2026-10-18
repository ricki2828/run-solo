import CoreLocation
import XCTest
@testable import Runner

/// P3: the Swift recorder wiring (RecorderHost -> Kotlin LiveRecorder -> journal -> finaliser).
/// Every replay scenario is fed through the host the way the Kotlin `ReplayRun` feeds the core,
/// so the finished run file must equal the contract fixture (parsed JSON equality).
final class RecorderHostTests: XCTestCase {
  private static let repoRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

  private func fixture(_ name: String) throws -> NSDictionary {
    let url = Self.repoRoot.appendingPathComponent("android/core-jvm/src/test/fixtures/contract/\(name).json")
    return try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? NSDictionary)
  }

  private func scratchDir() -> URL {
    URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("rec-" + UUID().uuidString, isDirectory: true)
  }

  /// A manual clock for live runs: device millis and wall millis advance together.
  private final class Clock {
    var t: Int64 = 5_000_000
    var w: Int64 = 1_760_000_000_000
    func advance(_ ms: Int64) { t += ms; w += ms }
    var recorderClock: RecorderClock { RecorderClock(monoMs: { self.t }, wallMs: { self.w }) }
  }

  func testEveryReplayKindThroughTheSwiftWiringMatchesItsKotlinFixture() throws {
    let kinds = CoreFacade.shared.replayKinds()
    XCTAssertGreaterThan(kinds.count, 10)
    for kind in kinds {
      let host = RecorderHost(root: scratchDir())
      let path = try XCTUnwrap(try host.runScenario(kind: kind), kind)
      XCTAssertTrue(FileManager.default.fileExists(atPath: path), kind)
      let got = try host.readRunFile(runId: "replay-\(kind)")
      let name = "replay_" + kind.replacingOccurrences(of: "-", with: "_")
      XCTAssertEqual(got as NSDictionary, try fixture(name), kind)
      XCTAssertNil(host.activeRunId)
      XCTAssertTrue(host.orphans().isEmpty, kind)
    }
  }

  /// Kill mid-run: the journal survives, the next open lists it (never the live run), the
  /// finaliser turns it into a run file once and is idempotent after.
  func testKillMidRunThenRecoverOnNextOpen() throws {
    let root = scratchDir()
    let first = RecorderHost(root: root)
    XCTAssertNil(try first.runScenario(kind: "4x4", killAfterFixes: 400))
    XCTAssertNil(first.activeRunId)

    let reopened = RecorderHost(root: root)
    let orphans = reopened.orphans()
    XCTAssertEqual(orphans.map(\.runId), ["replay-4x4"])
    let orphan = try XCTUnwrap(orphans.first)
    XCTAssertTrue(orphan.readable)
    XCTAssertFalse(orphan.newer)
    XCTAssertEqual(orphan.mode, .intervals)
    XCTAssertGreaterThan(orphan.elapsedMs, 300_000)
    let api = RecorderApiHost(host: reopened, source: LocationSource(manager: FakeLocationManager()), log: DiagnosticsLog(dir: scratchDir()))
    XCTAssertEqual(try api.recover().map(\.runId), ["replay-4x4"])
    XCTAssertEqual(try api.exitDiagnosis(runId: "replay-4x4").reason, .other)

    let path = try XCTUnwrap(try reopened.finalise(runId: "replay-4x4"))
    XCTAssertTrue(FileManager.default.fileExists(atPath: path))
    XCTAssertTrue(reopened.orphans().isEmpty)
    XCTAssertEqual(try reopened.finalise(runId: "replay-4x4"), path) // idempotent: already committed
    let run = try reopened.readRunFile(runId: "replay-4x4")
    XCTAssertEqual(run["schema"] as? Int, 7)
    XCTAssertNotEqual(run as NSDictionary, try fixture("replay_4x4")) // shorter than the full run
  }

  func testDiscardJournalRemovesTheOrphan() throws {
    let root = scratchDir()
    XCTAssertNil(try RecorderHost(root: root).runScenario(kind: "4x4", killAfterFixes: 50))
    let host = RecorderHost(root: root)
    XCTAssertEqual(host.orphans().count, 1)
    host.discardJournal(runId: "replay-4x4")
    XCTAssertTrue(host.orphans().isEmpty)
    XCTAssertNil(try host.finalise(runId: "replay-4x4"))
  }

  /// A live run with no heart rate: start, fixes, LAP, pause/resume, status, stop -> run file.
  func testLiveLapsRunLifecycleWithoutHeartRate() throws {
    let clock = Clock()
    var events: [RecorderEvent] = []
    let host = RecorderHost(root: scratchDir(), clock: clock.recorderClock, send: { events.append($0) })
    try host.start(runId: "live-1", mode: .laps, units: .km, tz: "Australia/Sydney")
    XCTAssertThrowsError(try host.start(runId: "live-2", mode: .free, units: .km))
    XCTAssertEqual(host.status().state, .recording)
    XCTAssertTrue(host.orphans().isEmpty) // the live journal is never an orphan
    var lat = -33.86
    func run(seconds: Int) {
      for _ in 0..<seconds {
        clock.advance(1_000)
        lat += 3.0 / 111_320 // ~3 m/s north
        host.feed(t: clock.t, w: clock.w, lat: lat, lon: 151.2, altM: 20, accuracyM: 5, speedMps: 3)
        host.tick()
      }
    }
    run(seconds: 90)
    XCTAssertEqual(host.lap(source: .button), "accepted")
    run(seconds: 30)
    host.pause()
    XCTAssertEqual(host.status().state, .paused)
    clock.advance(20_000)
    host.resume()
    run(seconds: 30)
    let status = host.status()
    XCTAssertEqual(status.state, .recording)
    XCTAssertEqual(status.runId, "live-1")
    XCTAssertGreaterThanOrEqual(status.lapIndex, 1)
    XCTAssertTrue(status.gpsFix)
    let path = try XCTUnwrap(try host.stop())
    XCTAssertTrue(path.hasSuffix("runs/run-live-1.json.gz"))
    XCTAssertEqual(host.status().state, .idle)
    XCTAssertNil(try host.stop())

    let file = try host.readRunFile(runId: "live-1")
    XCTAssertEqual(file["schema"] as? Int, 7)
    XCTAssertEqual(events.compactMap { $0 as? LapEvent }.count, 1)
    XCTAssertGreaterThan(events.compactMap { $0 as? TickEvent }.count, 140)
    XCTAssertEqual(events.compactMap { ($0 as? StateEvent)?.state }, [.recording, .paused, .recording, .idle])
    let lastTick = try XCTUnwrap(events.compactMap { $0 as? TickEvent }.last)
    XCTAssertGreaterThan(lastTick.totalDistanceM, 350)
  }

  func testStructuredSessionMapsToTheCore() throws {
    let spec = SessionSpec(
      templateId: "norwegian-4x4", templateVersion: 1, name: "Norwegian 4x4", warmupSeconds: nil, cooldownSeconds: nil,
      lapLockout: false, cueProfile: .standard, hrBandLow: 0.85, hrBandHigh: 0.95,
      steps: [
        SessionStep(kind: .work, target: .time, value: 240, style: .run, repIndex: 1),
        SessionStep(kind: .recovery, target: .time, value: 180, style: .jog, repIndex: 1),
        SessionStep(kind: .work, target: .time, value: 240, style: .run, repIndex: 2),
      ])
    let json = try JSONSerialization.jsonObject(with: Data(RecorderHost.specJson(spec).utf8)) as? [String: Any]
    XCTAssertEqual(json?["cueProfile"] as? String, "standard")
    XCTAssertEqual((json?["steps"] as? [[String: Any]])?.first?["target"] as? String, "time")
    let clock = Clock()
    let host = RecorderHost(root: scratchDir(), clock: clock.recorderClock)
    try host.start(runId: "live-4x4", mode: .intervals, spec: spec, units: .km)
    XCTAssertEqual(host.status().state, .recording)
    XCTAssertNotNil(try host.stop())
  }

  /// P2 review: the probe and the recorder share one LocationSource; neither steals the other's fixes
  /// and the probe stopping does not stop the recording's updates.
  func testProbeAndRecorderShareOneLocationSource() {
    let fake = FakeLocationManager()
    fake.authorizationStatus = .authorizedWhenInUse
    let source = LocationSource(manager: fake, makeActivity: { FakeActivity() })
    var probeFixes = 0, recorderFixes = 0
    source.addFixListener("probe") { _ in probeFixes += 1 }
    source.addFixListener("recorder") { _ in recorderFixes += 1 }
    source.start(owner: "probe")
    source.start(background: true, owner: "recorder")
    XCTAssertEqual(fake.startCalls, 1)
    fake.emit([CLLocation(latitude: 1, longitude: 2)])
    XCTAssertEqual(probeFixes, 1)
    XCTAssertEqual(recorderFixes, 1)
    source.stop(owner: "probe")
    XCTAssertTrue(source.running)
    XCTAssertTrue(fake.allowsBackgroundLocationUpdates)
    XCTAssertEqual(fake.stopCalls, 0)
    source.removeFixListener("probe")
    fake.emit([CLLocation(latitude: 1, longitude: 3)])
    XCTAssertEqual(probeFixes, 1)
    XCTAssertEqual(recorderFixes, 2)
    source.stop(owner: "recorder")
    XCTAssertFalse(source.running)
    XCTAssertFalse(fake.allowsBackgroundLocationUpdates)
    XCTAssertEqual(fake.stopCalls, 1)
  }

  // MARK: Diagnostics (B4)

  func testDiagnosticsLogRollsAndShares() throws {
    let log = DiagnosticsLog(dir: scratchDir(), maxBytes: 300)
    for i in 0..<20 { log.log("recorder", "line \(i) " + String(repeating: "x", count: 20)) }
    log.flush()
    XCTAssertTrue(FileManager.default.fileExists(atPath: log.current.path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: log.previous.path))
    let size = try XCTUnwrap(try FileManager.default.attributesOfItem(atPath: log.current.path)[.size] as? Int)
    XCTAssertLessThanOrEqual(size, 300)
    let shared = try String(contentsOf: try log.shareFile(), encoding: .utf8)
    XCTAssertTrue(shared.hasPrefix("Run Supreme diagnostics\n"))
    XCTAssertTrue(shared.contains("[recorder] line 19 "))
    XCTAssertFalse(shared.contains("[recorder] line 0 ")) // rolled out of both files
  }

  func testRecorderTraceReachesTheDiagnosticsLog() throws {
    let log = DiagnosticsLog(dir: scratchDir())
    let host = RecorderHost(root: scratchDir(), trace: { log.log("recorder", $0) })
    XCTAssertNotNil(try host.runScenario(kind: "4x4"))
    log.flush()
    let text = try String(contentsOf: log.current, encoding: .utf8)
    XCTAssertTrue(text.contains("[recorder] recorder start run=replay-4x4 mode=intervals"))
    XCTAssertTrue(text.contains("[recorder] recorder stop run=replay-4x4 file=runs/run-replay-4x4.json.gz"))
  }
}
