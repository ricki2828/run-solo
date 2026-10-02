import Foundation
import RunCore
import XCTest

/// K0: Swift drives the shared Kotlin recorder (replay -> core -> journal on disk -> finaliser ->
/// gzip run file) and gets the same run file the JVM wrote into the contract fixtures.
final class RunCoreSmokeTests: XCTestCase {
    private func fixture(_ name: String) throws -> NSDictionary {
        // spike/swift/Tests/RunCoreSmokeTests/<this file> -> repo root
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let url = root.appendingPathComponent("android/core-jvm/src/test/fixtures/contract/\(name).json")
        return try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! NSDictionary
    }

    func testReplay4x4MatchesTheJvmRunFile() throws {
        let facade = RunCoreFacade()
        XCTAssertTrue(facade.replayKinds().contains("4x4"))
        let dir = NSTemporaryDirectory() + "k0-swift-" + UUID().uuidString
        let json = try facade.replayRunFileJson(kind: "4x4", rootDir: dir)
        let got = try JSONSerialization.jsonObject(with: Data(json.utf8)) as! NSDictionary
        XCTAssertEqual(got["schema"] as? Int, 3)
        XCTAssertEqual(got, try fixture("replay_4x4"))
    }

    func testKotlinExceptionSurfacesAsSwiftError() {
        let dir = NSTemporaryDirectory() + "k0-swift-" + UUID().uuidString
        XCTAssertThrowsError(try RunCoreFacade().replayRunFileJson(kind: "no-such-kind", rootDir: dir))
    }

    func testJsonRoundTripThroughKotlinCodec() {
        let s = RunCoreFacade().normaliseJson(json: "{\"a\": [1, 2.5, \"x\"], \"b\": null}")
        XCTAssertEqual(s, "{\"a\":[1,2.5,\"x\"],\"b\":null}")
    }
}
