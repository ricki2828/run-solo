import XCTest
@testable import Runner

/// K3: Swift drives the shared Kotlin recorder through the XCFramework facade (replay -> core ->
/// journal on disk -> finaliser -> gzip run file) and gets the run file the JVM wrote into the
/// contract fixtures. Equality is parsed JSON (NSDictionary), as the plan's conformance rule.
final class CoreFacadeTests: XCTestCase {
  /// ios/RunnerTests/<this file> -> repo root. The simulator shares the host file system.
  private static let repoRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

  private func fixture(_ name: String) throws -> NSDictionary {
    let url = Self.repoRoot.appendingPathComponent("android/core-jvm/src/test/fixtures/contract/\(name).json")
    return try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? NSDictionary)
  }

  private func scratchDir() -> URL {
    URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("core-" + UUID().uuidString)
  }

  func testCoreVersionIsLinked() {
    XCTAssertFalse(CoreFacade.shared.coreVersion().isEmpty)
  }

  func testReplay4x4MatchesTheKotlinFixture() throws {
    XCTAssertTrue(CoreFacade.shared.replayKinds().contains("4x4"))
    let got = try CoreFacade.shared.replayRunFile(kind: "4x4", rootDir: scratchDir())
    XCTAssertEqual(got["schema"] as? Int, 8) // RunFile.SCHEMA
    XCTAssertEqual(got as NSDictionary, try fixture("replay_4x4"))
  }

  /// Every replay scenario, not just the 4x4: one fixture per kind (`replay_<kind>.json`).
  func testEveryReplayKindMatchesItsKotlinFixture() throws {
    let kinds = CoreFacade.shared.replayKinds()
    XCTAssertGreaterThan(kinds.count, 10)
    for kind in kinds {
      let got = try CoreFacade.shared.replayRunFile(kind: kind, rootDir: scratchDir())
      let name = "replay_" + kind.replacingOccurrences(of: "-", with: "_")
      XCTAssertEqual(got as NSDictionary, try fixture(name), kind)
    }
  }

  func testKotlinExceptionSurfacesAsSwiftError() {
    XCTAssertThrowsError(try CoreFacade.shared.replayRunFile(kind: "no-such-kind", rootDir: scratchDir()))
  }

  func testJsonRoundTripThroughKotlinCodec() throws {
    let s = try CoreFacade.shared.normaliseJson("{\"a\": [1, 2.5, \"x\"], \"b\": null}")
    XCTAssertEqual(s, "{\"a\":[1,2.5,\"x\"],\"b\":null}")
  }
}
