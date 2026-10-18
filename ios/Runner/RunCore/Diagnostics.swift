import Flutter
import Foundation
import MetricKit
import UIKit

/// In-app diagnostics log (iOS plan B4): there is no Mac to read device logs, so every field
/// failure must be explained by a file the runner can share. A rolling text file in Application
/// Support (`diagnostics/diagnostics.log`, rolled to `.1.log` at [maxBytes]) records recorder
/// lifecycle, location authorization changes, the fix rate, background / foreground moves,
/// memory warnings and MetricKit payloads. `shareFile()` joins both files under a device header.
final class DiagnosticsLog: NSObject {
  static let shared = DiagnosticsLog(dir: StorageDirs.support.appendingPathComponent("diagnostics", isDirectory: true))

  let dir: URL
  let maxBytes: Int
  private let queue = DispatchQueue(label: "app.runsupreme.diagnostics")
  private var observers: [NSObjectProtocol] = []
  private let stamp: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f
  }()

  var current: URL { dir.appendingPathComponent("diagnostics.log") }
  var previous: URL { dir.appendingPathComponent("diagnostics.1.log") }

  init(dir: URL, maxBytes: Int = 512 * 1024) {
    self.dir = dir
    self.maxBytes = maxBytes
    super.init()
  }

  deinit { for o in observers { NotificationCenter.default.removeObserver(o) } }

  /// Appends one line, `<ISO time> [<category>] <message>`. Never throws; a failed write is dropped.
  func log(_ category: String, _ message: String) {
    let line = "\(stamp.string(from: Date())) [\(category)] \(message)\n"
    queue.async { self.append(line) }
  }

  /// Waits for queued lines (tests, share).
  func flush() { queue.sync {} }

  private func append(_ line: String) {
    let fm = FileManager.default
    do {
      try fm.createDirectory(at: dir, withIntermediateDirectories: true)
      let size = (try? fm.attributesOfItem(atPath: current.path)[.size] as? Int) ?? 0
      if size + line.utf8.count > maxBytes, size > 0 {
        try? fm.removeItem(at: previous)
        try fm.moveItem(at: current, to: previous)
      }
      if !fm.fileExists(atPath: current.path) { fm.createFile(atPath: current.path, contents: nil) }
      let handle = try FileHandle(forWritingTo: current)
      defer { try? handle.close() }
      try handle.seekToEnd()
      try handle.write(contentsOf: Data(line.utf8))
    } catch {
      NSLog("RunSupreme: diagnostics write failed: \(error)")
    }
  }

  /// One shareable text file: device header, then the previous and current logs.
  func shareFile() throws -> URL {
    flush()
    return try queue.sync {
      let device = UIDevice.current
      let info = Bundle.main.infoDictionary
      var text = "Run Supreme diagnostics\n"
      text += "app \(info?["CFBundleShortVersionString"] as? String ?? "?") (\(info?["CFBundleVersion"] as? String ?? "?"))\n"
      text += "device \(Self.modelIdentifier()) \(device.systemName) \(device.systemVersion)\n"
      text += "written \(stamp.string(from: Date()))\n\n"
      for url in [previous, current] {
        if let s = try? String(contentsOf: url, encoding: .utf8) { text += s }
      }
      let out = dir.appendingPathComponent("run-supreme-diagnostics.txt")
      try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
      try Data(text.utf8).write(to: out, options: .atomic)
      return out
    }
  }

  static func modelIdentifier() -> String {
    var info = utsname()
    uname(&info)
    return withUnsafeBytes(of: &info.machine) { raw in
      String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
    }
  }

  // MARK: System events

  /// Logs app lifecycle and memory warnings, and subscribes to MetricKit. Call once at launch.
  func observeSystem(center: NotificationCenter = .default) {
    let names: [(Notification.Name, String)] = [
      (UIApplication.didEnterBackgroundNotification, "entered background"),
      (UIApplication.willEnterForegroundNotification, "entering foreground"),
      (UIApplication.didBecomeActiveNotification, "active"),
      (UIApplication.willResignActiveNotification, "resigning active"),
      (UIApplication.willTerminateNotification, "terminating"),
      (UIApplication.didReceiveMemoryWarningNotification, "memory warning"),
      (UIApplication.protectedDataWillBecomeUnavailableNotification, "protected data locking"),
      (UIApplication.protectedDataDidBecomeAvailableNotification, "protected data available"),
    ]
    for (name, text) in names {
      observers.append(center.addObserver(forName: name, object: nil, queue: nil) { [weak self] _ in
        self?.log(name == UIApplication.didReceiveMemoryWarningNotification ? "memory" : "lifecycle", text)
      })
    }
    MXMetricManager.shared.add(self)
    log("lifecycle", "launch \(Self.modelIdentifier()) iOS \(UIDevice.current.systemVersion)")
  }
}

extension DiagnosticsLog: MXMetricManagerSubscriber {
  func didReceive(_ payloads: [MXMetricPayload]) {
    for p in payloads { log("metrickit", String(decoding: p.jsonRepresentation(), as: UTF8.self)) }
  }

  func didReceive(_ payloads: [MXDiagnosticPayload]) {
    for p in payloads { log("metrickit-diagnostic", String(decoding: p.jsonRepresentation(), as: UTF8.self)) }
  }
}

/// The Share hook (B4): method channel `app.runsupreme/diagnostics`.
/// - `path` -> the shareable file's path (for Dart's share_plus, a Settings "Share diagnostics" row).
/// - `share` -> presents the iOS share sheet for that file directly (no Dart plugin needed).
/// - `log` (String) -> appends a Dart-side line under category `dart`.
enum DiagnosticsChannel {
  static let name = "app.runsupreme/diagnostics"

  static func register(with messenger: FlutterBinaryMessenger, log: DiagnosticsLog = .shared) {
    let channel = FlutterMethodChannel(name: name, binaryMessenger: messenger)
    channel.setMethodCallHandler { call, result in
      switch call.method {
      case "path":
        do { result(try log.shareFile().path) } catch { result(FlutterError(code: "io", message: "\(error)", details: nil)) }
      case "share":
        do {
          let url = try log.shareFile()
          present(url)
          result(true)
        } catch { result(FlutterError(code: "io", message: "\(error)", details: nil)) }
      case "log":
        log.log("dart", call.arguments as? String ?? "")
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  private static func present(_ url: URL) {
    let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
    guard var top = scenes.flatMap(\.windows).first(where: \.isKeyWindow)?.rootViewController else { return }
    while let next = top.presentedViewController { top = next }
    let sheet = UIActivityViewController(activityItems: [url], applicationActivities: nil)
    sheet.popoverPresentationController?.sourceView = top.view
    top.present(sheet, animated: true)
  }
}
