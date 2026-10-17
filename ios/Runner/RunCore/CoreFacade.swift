import Foundation
// Internal import: the Kotlin framework is linked into Runner only. RunnerTests (hosted in
// Runner) must not need the module, or it would link a second copy of the Kotlin runtime.
internal import RunCore

/// Swift face of the shared Kotlin recorder core (iOS plan §2.2, K3). The XCFramework's API is
/// ObjC-flavoured (`RunCoreFacade`: Strings and lists in and out, Kotlin exceptions as `NSError`);
/// this wraps it so the rest of the app sees Swift types only. The core is not thread-safe, so
/// every call runs on one serial queue.
final class CoreFacade {
  static let shared = CoreFacade()

  private let queue = DispatchQueue(label: "app.runsupreme.core")
  private let kotlin = RunCoreFacade()

  /// `CoreVersion.VERSION` of the linked core.
  func coreVersion() -> String {
    queue.sync { kotlin.coreVersion() }
  }

  /// The replay scenarios the core can run (`ReplayScenarios.KINDS`).
  func replayKinds() -> [String] {
    queue.sync { kotlin.replayKinds() }
  }

  /// Records replay `kind` through the real core into `rootDir` (journal, finaliser, gzip run
  /// file) and returns the finished run file as parsed JSON.
  func replayRunFile(kind: String, rootDir: URL) throws -> [String: Any] {
    let json = try queue.sync { try kotlin.replayRunFileJson(kind: kind, rootDir: rootDir.path) }
    guard let object = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] else {
      throw CoreFacadeError.notAnObject
    }
    return object
  }

  /// Re-serialises JSON through the core's own codec.
  func normaliseJson(_ json: String) throws -> String {
    try queue.sync { try kotlin.normaliseJson(json: json) }
  }
}

enum CoreFacadeError: Error {
  case notAnObject
}
