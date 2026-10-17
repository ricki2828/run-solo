import CoreLocation
import UIKit
import XCTest

@testable import Runner

final class FakeLocationManager: LocationManaging {
  weak var delegate: CLLocationManagerDelegate?
  var desiredAccuracy: CLLocationAccuracy = 0
  var distanceFilter: CLLocationDistance = 0
  var activityType: CLActivityType = .other
  var allowsBackgroundLocationUpdates = false
  var pausesLocationUpdatesAutomatically = true
  var showsBackgroundLocationIndicator = false
  var authorizationStatus: CLAuthorizationStatus = .notDetermined
  var accuracyAuthorization: CLAccuracyAuthorization = .fullAccuracy
  var servicesEnabled = true
  private(set) var whenInUseRequests = 0
  private(set) var alwaysRequests = 0
  private(set) var startCalls = 0
  private(set) var stopCalls = 0
  /// What the system answers to the next `requestWhenInUseAuthorization`.
  var answer: CLAuthorizationStatus = .authorizedWhenInUse

  // The delegate callbacks ignore their manager argument.
  private let placeholder = CLLocationManager()

  func requestWhenInUseAuthorization() {
    whenInUseRequests += 1
    setStatus(answer)
  }

  func requestAlwaysAuthorization() { alwaysRequests += 1 }
  func startUpdatingLocation() { startCalls += 1 }
  func stopUpdatingLocation() { stopCalls += 1 }

  func setStatus(_ status: CLAuthorizationStatus) {
    authorizationStatus = status
    delegate?.locationManagerDidChangeAuthorization?(placeholder)
  }

  func emit(_ locations: [CLLocation]) {
    delegate?.locationManager?(placeholder, didUpdateLocations: locations)
  }
}

final class FakeActivity: BackgroundActivityHandle {
  var ended = false
  func end() { ended = true }
}

/// Parses the simulator route in `Resources/probe-route.gpx` (also usable as an Xcode scheme
/// simulated location). Located through `#filePath`: simulator tests run on the Mac that has the
/// source tree, so no resource-bundle wiring in the pbxproj is needed.
enum GPXRoute {
  static func load(file: String = #filePath) throws -> [CLLocation] {
    let url = URL(fileURLWithPath: file).deletingLastPathComponent().appendingPathComponent("Resources/probe-route.gpx")
    let parser = XMLParser(data: try Data(contentsOf: url))
    let delegate = Delegate()
    parser.delegate = delegate
    XCTAssertTrue(parser.parse())
    return delegate.points
  }

  private final class Delegate: NSObject, XMLParserDelegate {
    var points: [CLLocation] = []
    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
      guard name == "trkpt", let lat = Double(attributes["lat"] ?? ""), let lon = Double(attributes["lon"] ?? "") else { return }
      points.append(CLLocation(coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lon), altitude: 40, horizontalAccuracy: 5, verticalAccuracy: 5, timestamp: Date()))
    }
  }
}

final class LocationSourceTests: XCTestCase {
  func testConfiguresForRecordingAccuracy() {
    let fake = FakeLocationManager()
    _ = LocationSource(manager: fake)
    XCTAssertEqual(fake.desiredAccuracy, kCLLocationAccuracyBest)
    XCTAssertEqual(fake.distanceFilter, kCLDistanceFilterNone)
    XCTAssertEqual(fake.activityType, .fitness)
    XCTAssertFalse(fake.pausesLocationUpdatesAutomatically)
  }

  func testForegroundStartDoesNotEnableBackground() {
    let fake = FakeLocationManager()
    let source = LocationSource(manager: fake)
    source.start()
    XCTAssertEqual(fake.startCalls, 1)
    XCTAssertFalse(fake.allowsBackgroundLocationUpdates)
  }

  func testBackgroundStartAndStopManageSessionAndIndicator() {
    let fake = FakeLocationManager()
    let activity = FakeActivity()
    let source = LocationSource(manager: fake, makeActivity: { activity })
    source.start(background: true)
    XCTAssertTrue(fake.allowsBackgroundLocationUpdates)
    XCTAssertTrue(fake.showsBackgroundLocationIndicator)
    XCTAssertFalse(activity.ended)
    source.stop()
    XCTAssertFalse(fake.allowsBackgroundLocationUpdates)
    XCTAssertFalse(fake.showsBackgroundLocationIndicator)
    XCTAssertTrue(activity.ended)
    XCTAssertEqual(fake.stopCalls, 1)
  }

  func testStartIsIdempotentAndStopWithoutStartIsQuiet() {
    let fake = FakeLocationManager()
    let source = LocationSource(manager: fake)
    source.stop()
    XCTAssertEqual(fake.stopCalls, 0)
    source.start()
    source.start()
    XCTAssertEqual(fake.startCalls, 1)
  }

  func testForwardsFixesAndAuthorizationChanges() {
    let fake = FakeLocationManager()
    let source = LocationSource(manager: fake)
    var fixes = 0
    var changes = 0
    source.onFix = { _ in fixes += 1 }
    source.onAuthorizationChange = { changes += 1 }
    fake.emit([CLLocation(latitude: 1, longitude: 2), CLLocation(latitude: 1, longitude: 3)])
    fake.setStatus(.denied)
    XCTAssertEqual(fixes, 2)
    XCTAssertEqual(changes, 1)
  }
}

final class GpsProbeTests: XCTestCase {
  private var clock: TimeInterval = 1000
  private var events: [GpsProbeEvent] = []
  private var tickBlock: (() -> Void)?
  private var cancelled = false

  private struct Cancel: Cancelling {
    let run: () -> Void
    func cancel() { run() }
  }

  private func makeProbe(fake: FakeLocationManager, notifications: NotificationCenter = NotificationCenter()) -> GpsProbe {
    GpsProbe(
      source: LocationSource(manager: fake),
      notifications: notifications,
      now: { self.clock },
      schedule: { block in
        self.tickBlock = block
        self.cancelled = false
        return Cancel { self.cancelled = true }
      },
      send: { self.events.append($0) }
    )
  }

  private func fix(_ lat: Double, _ lon: Double, accuracy: Double = 6) -> CLLocation {
    CLLocation(coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lon), altitude: 0, horizontalAccuracy: accuracy, verticalAccuracy: 5, timestamp: Date())
  }

  func testNoFixYetReportsFixFalse() {
    let fake = FakeLocationManager()
    let probe = makeProbe(fake: fake)
    probe.start()
    XCTAssertEqual(events.count, 1)
    XCTAssertEqual(events[0], GpsProbeEvent(fix: false))
    XCTAssertEqual(fake.startCalls, 1)
  }

  func testFreshFixCarriesPositionAccuracyAndAge() {
    let fake = FakeLocationManager()
    let probe = makeProbe(fake: fake)
    probe.start()
    fake.emit([fix(-33.9, 151.2, accuracy: 4.5)])
    clock += 1.2
    tickBlock?()
    let e = events.last!
    XCTAssertTrue(e.fix)
    XCTAssertEqual(e.lat, -33.9)
    XCTAssertEqual(e.lon, 151.2)
    XCTAssertEqual(e.accuracyM, 4.5)
    XCTAssertEqual(e.fixAgeMs, 1200)
  }

  func testStaleFixDropsPositionButKeepsAge() {
    let fake = FakeLocationManager()
    let probe = makeProbe(fake: fake)
    probe.start()
    fake.emit([fix(1, 2)])
    clock += 5.5
    tickBlock?()
    let e = events.last!
    XCTAssertFalse(e.fix)
    XCTAssertNil(e.lat)
    XCTAssertNil(e.accuracyM)
    XCTAssertEqual(e.fixAgeMs, 5500)
  }

  func testInvalidAccuracyIsNotAFix() {
    let fake = FakeLocationManager()
    let probe = makeProbe(fake: fake)
    probe.start()
    fake.emit([fix(1, 2, accuracy: -1)])
    tickBlock?()
    XCTAssertFalse(events.last!.fix)
  }

  func testStartIsIdempotentAndStopCancelsTimerAndSource() {
    let fake = FakeLocationManager()
    let probe = makeProbe(fake: fake)
    probe.start()
    probe.start()
    XCTAssertEqual(fake.startCalls, 1)
    XCTAssertTrue(probe.running)
    probe.stop()
    XCTAssertFalse(probe.running)
    XCTAssertTrue(cancelled)
    XCTAssertEqual(fake.stopCalls, 1)
  }

  func testEnteringBackgroundStopsTheProbe() {
    let center = NotificationCenter()
    let fake = FakeLocationManager()
    let probe = makeProbe(fake: fake, notifications: center)
    probe.start()
    center.post(name: UIApplication.didEnterBackgroundNotification, object: nil)
    // The observer hops to the main queue.
    let spin = expectation(description: "main queue")
    DispatchQueue.main.async { spin.fulfill() }
    wait(for: [spin], timeout: 2)
    XCTAssertFalse(probe.running)
    XCTAssertEqual(fake.stopCalls, 1)
  }

  /// The GPX route plays through the fake manager at 1 Hz; each tick reports the latest point.
  func testGpxRouteDrivesProbeEvents() throws {
    let route = try GPXRoute.load()
    XCTAssertGreaterThanOrEqual(route.count, 20)
    let fake = FakeLocationManager()
    let probe = makeProbe(fake: fake)
    probe.start()
    for point in route {
      fake.emit([point])
      clock += 1
      tickBlock?()
    }
    let fixes = events.dropFirst()
    XCTAssertEqual(fixes.count, route.count)
    XCTAssertTrue(fixes.allSatisfy { $0.fix })
    for (event, point) in zip(fixes, route) {
      XCTAssertEqual(event.lat, point.coordinate.latitude)
      XCTAssertEqual(event.lon, point.coordinate.longitude)
      XCTAssertEqual(event.fixAgeMs, 1000)
    }
    // The route actually moves: first and last differ by well over GPS noise.
    let a = route.first!, b = route.last!
    XCTAssertGreaterThan(a.distance(from: b), 50)
  }
}

final class PermissionsHostTests: XCTestCase {
  private func status(_ host: PermissionsHost) throws -> PermissionStatus { try host.permissionStatus() }

  func testNotDeterminedReadsNotGranted() throws {
    let fake = FakeLocationManager()
    let s = try status(PermissionsHost(manager: fake))
    XCTAssertFalse(s.fineLocation)
    XCTAssertFalse(s.approximateOnly)
    XCTAssertTrue(s.locationEnabled)
    XCTAssertTrue(s.notifications && s.bluetooth && s.batteryUnrestricted && s.gmsAvailable)
  }

  func testWhenInUseAndAlwaysBothCountAsFine() throws {
    let fake = FakeLocationManager()
    let host = PermissionsHost(manager: fake)
    fake.authorizationStatus = .authorizedWhenInUse
    XCTAssertTrue(try status(host).fineLocation)
    fake.authorizationStatus = .authorizedAlways
    XCTAssertTrue(try status(host).fineLocation)
    fake.authorizationStatus = .denied
    XCTAssertFalse(try status(host).fineLocation)
    fake.authorizationStatus = .restricted
    XCTAssertFalse(try status(host).fineLocation)
  }

  func testReducedAccuracyIsApproximateOnly() throws {
    let fake = FakeLocationManager()
    let host = PermissionsHost(manager: fake)
    fake.authorizationStatus = .authorizedWhenInUse
    fake.accuracyAuthorization = .reducedAccuracy
    let s = try status(host)
    XCTAssertTrue(s.fineLocation)
    XCTAssertTrue(s.approximateOnly)
  }

  func testLocationServicesOffIsReported() throws {
    let fake = FakeLocationManager()
    fake.servicesEnabled = false
    XCTAssertFalse(try status(PermissionsHost(manager: fake)).locationEnabled)
  }

  func testRequestLocationAsksWhenInUseOnceAndResolvesOnAnswer() {
    let fake = FakeLocationManager()
    let host = PermissionsHost(manager: fake)
    var result: Bool?
    host.requestPermission(kind: .location) { if case .success(let v) = $0 { result = v } }
    XCTAssertEqual(fake.whenInUseRequests, 1)
    XCTAssertEqual(fake.alwaysRequests, 0)
    XCTAssertEqual(result, true)
  }

  func testRequestLocationDeniedResolvesFalse() {
    let fake = FakeLocationManager()
    fake.answer = .denied
    let host = PermissionsHost(manager: fake)
    var result: Bool?
    host.requestPermission(kind: .location) { if case .success(let v) = $0 { result = v } }
    XCTAssertEqual(result, false)
  }

  func testRequestWaitsForTheUserAnswer() {
    let fake = FakeLocationManager()
    fake.answer = .notDetermined
    let host = PermissionsHost(manager: fake)
    var result: Bool?
    host.requestPermission(kind: .location) { if case .success(let v) = $0 { result = v } }
    XCTAssertNil(result)
    fake.setStatus(.authorizedWhenInUse)
    XCTAssertEqual(result, true)
  }

  func testRequestWhenAlreadyDecidedDoesNotPromptAgain() {
    let fake = FakeLocationManager()
    fake.authorizationStatus = .denied
    let host = PermissionsHost(manager: fake)
    var result: Bool?
    host.requestPermission(kind: .location) { if case .success(let v) = $0 { result = v } }
    XCTAssertEqual(fake.whenInUseRequests, 0)
    XCTAssertEqual(result, false)
  }

  func testNotificationsAndBluetoothResolveTrueWithoutPrompt() {
    let fake = FakeLocationManager()
    let host = PermissionsHost(manager: fake)
    for kind in [PermissionKind.notifications, .bluetooth] {
      var result: Bool?
      host.requestPermission(kind: kind) { if case .success(let v) = $0 { result = v } }
      XCTAssertEqual(result, true)
    }
    XCTAssertEqual(fake.whenInUseRequests, 0)
  }

  func testAlwaysUpgradeOnlyFromWhenInUse() {
    let fake = FakeLocationManager()
    let host = PermissionsHost(manager: fake)
    host.requestAlwaysUpgrade()
    XCTAssertEqual(fake.alwaysRequests, 0)
    fake.authorizationStatus = .authorizedWhenInUse
    host.requestAlwaysUpgrade()
    XCTAssertEqual(fake.alwaysRequests, 1)
  }

  func testKeepScreenOnAndSettingsHooks() throws {
    let fake = FakeLocationManager()
    var idle: [Bool] = []
    var opened: [URL] = []
    let host = PermissionsHost(manager: fake, openURL: { opened.append($0) }, setIdleTimerDisabled: { idle.append($0) })
    try host.setKeepScreenOn(enabled: true)
    try host.setKeepScreenOn(enabled: false)
    try host.openAppSettings()
    try host.openBatterySettings()
    let spin = expectation(description: "main queue")
    DispatchQueue.main.async { spin.fulfill() }
    wait(for: [spin], timeout: 2)
    XCTAssertEqual(idle, [true, false])
    XCTAssertEqual(opened.count, 2)
    XCTAssertFalse(try host.volumeKeyLapsSupported())
  }
}
