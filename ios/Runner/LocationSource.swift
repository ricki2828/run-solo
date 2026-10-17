import CoreLocation
import UIKit

// CoreLocation adapters for the recorder and the Start screen (iOS plan §2.4, §4). Everything
// talks to `LocationManaging`, so XCTests drive it with a fake instead of CLLocationManager.

/// The slice of `CLLocationManager` the app uses.
protocol LocationManaging: AnyObject {
  var delegate: CLLocationManagerDelegate? { get set }
  var desiredAccuracy: CLLocationAccuracy { get set }
  var distanceFilter: CLLocationDistance { get set }
  var activityType: CLActivityType { get set }
  var allowsBackgroundLocationUpdates: Bool { get set }
  var pausesLocationUpdatesAutomatically: Bool { get set }
  var showsBackgroundLocationIndicator: Bool { get set }
  var authorizationStatus: CLAuthorizationStatus { get }
  var accuracyAuthorization: CLAccuracyAuthorization { get }
  var servicesEnabled: Bool { get }
  func requestWhenInUseAuthorization()
  func requestAlwaysAuthorization()
  func startUpdatingLocation()
  func stopUpdatingLocation()
}

extension CLLocationManager: LocationManaging {
  var servicesEnabled: Bool { CLLocationManager.locationServicesEnabled() }
}

/// Keeps a run alive with the screen locked on iOS 17+ (started while foregrounded).
protocol BackgroundActivityHandle: AnyObject { func end() }

final class SystemBackgroundActivity: BackgroundActivityHandle {
  private let session = CLBackgroundActivitySession()
  func end() { session.invalidate() }
}

/// Streams fixes from a location manager. Foreground-only until `enableBackground()` (recording).
final class LocationSource: NSObject, CLLocationManagerDelegate {
  private let manager: LocationManaging
  private let makeActivity: () -> BackgroundActivityHandle
  private var activity: BackgroundActivityHandle?
  private(set) var running = false

  /// Every fix, on the thread CoreLocation calls back on (main for a main-thread manager).
  var onFix: ((CLLocation) -> Void)?
  /// Authorization changed (including downgrades mid-run).
  var onAuthorizationChange: (() -> Void)?
  var onError: ((Error) -> Void)?

  init(
    manager: LocationManaging = CLLocationManager(),
    makeActivity: @escaping () -> BackgroundActivityHandle = { SystemBackgroundActivity() }
  ) {
    self.manager = manager
    self.makeActivity = makeActivity
    super.init()
    manager.delegate = self
    // The recording's settings: the core's PointFilter does the filtering, as in Android raw mode.
    manager.desiredAccuracy = kCLLocationAccuracyBest
    manager.distanceFilter = kCLDistanceFilterNone
    manager.activityType = .fitness
    manager.pausesLocationUpdatesAutomatically = false
  }

  /// Start updates. Pass `background: true` for a recording started from the foreground.
  func start(background: Bool = false) {
    if background { enableBackground() }
    guard !running else { return }
    running = true
    manager.startUpdatingLocation()
  }

  func stop() {
    guard running else { return }
    running = false
    manager.stopUpdatingLocation()
    disableBackground()
  }

  private func enableBackground() {
    manager.allowsBackgroundLocationUpdates = true
    manager.showsBackgroundLocationIndicator = true
    if activity == nil { activity = makeActivity() }
  }

  private func disableBackground() {
    manager.allowsBackgroundLocationUpdates = false
    manager.showsBackgroundLocationIndicator = false
    activity?.end()
    activity = nil
  }

  // MARK: CLLocationManagerDelegate

  func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
    for location in locations { onFix?(location) }
  }

  func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
    onError?(error)
  }

  func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
    onAuthorizationChange?()
  }
}

/// Pre-start GPS readiness for the Start screen: about one `GpsProbeEvent` a second while running.
/// Foreground only; stops when the app enters the background.
final class GpsProbe {
  static let freshFixMs: Int64 = 5_000

  private let source: LocationSource
  private let now: () -> TimeInterval
  private let schedule: (@escaping () -> Void) -> Cancelling
  private let send: (GpsProbeEvent) -> Void
  private var timer: Cancelling?
  private let notifications: NotificationCenter
  private var observer: NSObjectProtocol?
  private var last: (location: CLLocation, arrival: TimeInterval)?

  init(
    source: LocationSource,
    notifications: NotificationCenter = .default,
    now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
    schedule: @escaping (@escaping () -> Void) -> Cancelling = GpsProbe.mainTimer,
    send: @escaping (GpsProbeEvent) -> Void
  ) {
    self.source = source
    self.notifications = notifications
    self.now = now
    self.schedule = schedule
    self.send = send
    observer = notifications.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
      self?.stop()
    }
    source.onFix = { [weak self] location in
      guard let self else { return }
      self.last = (location, self.now())
    }
  }

  deinit { if let observer { notifications.removeObserver(observer) } }

  var running: Bool { timer != nil }

  /// Idempotent.
  func start() {
    guard timer == nil else { return }
    last = nil
    source.start(background: false)
    timer = schedule { [weak self] in self?.tick() }
    tick()
  }

  func stop() {
    timer?.cancel()
    timer = nil
    source.stop()
    last = nil
  }

  func tick() {
    send(event())
  }

  func event() -> GpsProbeEvent {
    guard let last else { return GpsProbeEvent(fix: false) }
    let ageMs = Int64(max(0, now() - last.arrival) * 1000)
    // A negative horizontalAccuracy means CoreLocation has no valid position.
    let valid = last.location.horizontalAccuracy >= 0
    let fresh = valid && ageMs <= GpsProbe.freshFixMs
    return GpsProbeEvent(
      fix: fresh,
      lat: fresh ? last.location.coordinate.latitude : nil,
      lon: fresh ? last.location.coordinate.longitude : nil,
      accuracyM: fresh ? last.location.horizontalAccuracy : nil,
      fixAgeMs: ageMs
    )
  }

  static func mainTimer(_ fire: @escaping () -> Void) -> Cancelling {
    let timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in fire() }
    return TimerHandle(timer: timer)
  }
}

protocol Cancelling { func cancel() }

private struct TimerHandle: Cancelling {
  let timer: Timer
  func cancel() { timer.invalidate() }
}
