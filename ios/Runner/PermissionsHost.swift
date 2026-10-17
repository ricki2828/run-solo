import CoreLocation
import UIKit

/// `PermissionsApi` on CoreLocation (iOS plan §2.4). Notifications, bluetooth (no strap in
/// Phase 1), battery and gms are Android concepts or out of scope: true keeps the Dart checklist
/// and `canRecord` gate passing.
final class PermissionsHost: NSObject, PermissionsApi, CLLocationManagerDelegate {
  private let manager: LocationManaging
  private let openURL: (URL) -> Void
  private let setIdleTimerDisabled: (Bool) -> Void
  private var pending: [(Result<Bool, Error>) -> Void] = []

  init(
    manager: LocationManaging = CLLocationManager(),
    openURL: @escaping (URL) -> Void = { UIApplication.shared.open($0) },
    setIdleTimerDisabled: @escaping (Bool) -> Void = { UIApplication.shared.isIdleTimerDisabled = $0 }
  ) {
    self.manager = manager
    self.openURL = openURL
    self.setIdleTimerDisabled = setIdleTimerDisabled
    super.init()
    manager.delegate = self
  }

  private var authorized: Bool {
    switch manager.authorizationStatus {
    case .authorizedWhenInUse, .authorizedAlways: return true
    default: return false
    }
  }

  /// Precise only, as Android's `fine`: with Approximate the Dart setup row must read blocked,
  /// not ok, since `canRecord` needs `fineLocation && !coarseOnly`.
  private var fineLocation: Bool { authorized && manager.accuracyAuthorization == .fullAccuracy }

  func permissionStatus() throws -> PermissionStatus {
    PermissionStatus(
      fineLocation: fineLocation,
      approximateOnly: authorized && manager.accuracyAuthorization == .reducedAccuracy,
      locationEnabled: manager.servicesEnabled,
      notifications: true,
      bluetooth: true,
      batteryUnrestricted: true,
      gmsAvailable: true
    )
  }

  /// Location asks for When-In-Use only (no "Always": the run is started in the foreground and
  /// the background indicator covers the rest). Resolves once the user answers; already
  /// answered resolves at once with the current state.
  func requestPermission(kind: PermissionKind, completion: @escaping (Result<Bool, Error>) -> Void) {
    switch kind {
    case .location:
      if manager.authorizationStatus == .notDetermined {
        pending.append(completion)
        manager.requestWhenInUseAuthorization()
      } else {
        completion(.success(fineLocation))
      }
    case .notifications:
      completion(.success(true))
    case .bluetooth:
      // Phase 1 has no strap; the status already reads true.
      completion(.success(true))
    }
  }

  /// Upgrade path When-In-Use -> Always. Not reachable from Dart and not used in Phase 1 (plan
  /// §7.1: no "Always" scrutiny); here so a later phase can ask without reworking this class.
  /// iOS only shows the second prompt after When-In-Use was granted.
  func requestAlwaysUpgrade() {
    guard manager.authorizationStatus == .authorizedWhenInUse else { return }
    manager.requestAlwaysAuthorization()
  }

  func openBatterySettings() throws { try openAppSettings() }

  func openAppSettings() throws {
    guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
    DispatchQueue.main.async { [openURL] in openURL(url) }
  }

  func setKeepScreenOn(enabled: Bool) throws {
    DispatchQueue.main.async { [setIdleTimerDisabled] in setIdleTimerDisabled(enabled) }
  }

  func volumeKeyLapsSupported() throws -> Bool { false }

  // MARK: CLLocationManagerDelegate

  func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
    guard self.manager.authorizationStatus != .notDetermined, !pending.isEmpty else { return }
    let granted = fineLocation
    let waiting = pending
    pending = []
    for completion in waiting { completion(.success(granted)) }
  }
}
