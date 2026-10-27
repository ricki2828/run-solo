import CoreBluetooth
import Foundation

/// The one real `BleCentral`: CoreBluetooth plumbing only, no policy. Needs a device with a
/// Bluetooth radio (the simulator has none), so it is exercised only by hand on an iPhone; the
/// client logic above it is covered by XCTests with a fake central.
final class CoreBluetoothCentral: NSObject, BleCentral, CBCentralManagerDelegate, CBPeripheralDelegate {
  static let hrService = CBUUID(string: "180D")
  static let hrMeasurement = CBUUID(string: "2A37")

  weak var delegate: BleCentralDelegate?
  private var manager: CBCentralManager!
  private var known: [UUID: CBPeripheral] = [:]  // CoreBluetooth drops peripherals nobody retains

  /// Delegate callbacks arrive on the main queue (the client is main-queue only).
  override init() {
    super.init()
    manager = CBCentralManager(delegate: self, queue: .main, options: [CBCentralManagerOptionShowPowerAlertKey: true])
  }

  var poweredOn: Bool { manager.state == .poweredOn }

  var authorized: Bool {
    switch CBManager.authorization {
    case .denied, .restricted: return false
    default: return true
    }
  }

  var stateResolved: Bool {
    switch manager.state {
    case .unknown, .resetting: return false
    default: return CBManager.authorization != .notDetermined
    }
  }

  func startScan() -> Bool {
    guard poweredOn else { return false }
    // Duplicates on: a strap first seen without its name is reported again once the name arrives.
    manager.scanForPeripherals(withServices: [Self.hrService], options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
    return true
  }

  func stopScan() { manager.stopScan() }

  func connect(id: String) -> Bool {
    guard let uuid = UUID(uuidString: id) else { return false }
    guard let peripheral = known[uuid] ?? manager.retrievePeripherals(withIdentifiers: [uuid]).first else { return false }
    known[uuid] = peripheral
    peripheral.delegate = self
    // No timeout: a pending connect completes whenever the strap appears (Android's autoConnect).
    manager.connect(peripheral, options: nil)
    return true
  }

  func cancel(id: String) {
    guard let uuid = UUID(uuidString: id), let peripheral = known[uuid] else { return }
    manager.cancelPeripheralConnection(peripheral)
  }

  func beginSetup(id: String) {
    guard let uuid = UUID(uuidString: id), let peripheral = known[uuid] else { return }
    peripheral.discoverServices([Self.hrService])
  }

  // MARK: CBCentralManagerDelegate

  func centralManagerDidUpdateState(_ central: CBCentralManager) { delegate?.centralDidChangeState() }

  func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
    known[peripheral.identifier] = peripheral
    // The advertised local name is the one that rotates least; the cached GAP name may be stale or empty.
    let name = (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? peripheral.name
    delegate?.central(didDiscover: BleAdvert(id: peripheral.identifier.uuidString, name: name, rssi: RSSI.intValue))
  }

  func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
    delegate?.centralDidConnect(id: peripheral.identifier.uuidString)
  }

  func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
    delegate?.centralDidDisconnect(id: peripheral.identifier.uuidString)
  }

  func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
    // A cancel the client issued before re-connecting the same peripheral reports its disconnect
    // late, after the new connect is already under way: that one is not a drop.
    guard peripheral.state == .disconnected else { return }
    delegate?.centralDidDisconnect(id: peripheral.identifier.uuidString)
  }

  // MARK: CBPeripheralDelegate

  func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
    let id = peripheral.identifier.uuidString
    guard error == nil, let service = peripheral.services?.first(where: { $0.uuid == Self.hrService }) else {
      delegate?.centralSetupFailed(id: id, what: "services \(error?.localizedDescription ?? "no 0x180D")")
      return
    }
    peripheral.discoverCharacteristics([Self.hrMeasurement], for: service)
  }

  func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
    let id = peripheral.identifier.uuidString
    guard error == nil, let ch = service.characteristics?.first(where: { $0.uuid == Self.hrMeasurement }) else {
      delegate?.centralSetupFailed(id: id, what: "characteristics \(error?.localizedDescription ?? "no 0x2A37")")
      return
    }
    peripheral.setNotifyValue(true, for: ch)
  }

  func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
    guard characteristic.uuid == Self.hrMeasurement else { return }
    let id = peripheral.identifier.uuidString
    if error == nil, characteristic.isNotifying {
      delegate?.centralNotificationsReady(id: id)
    } else {
      delegate?.centralSetupFailed(id: id, what: "subscribe \(error?.localizedDescription ?? "not notifying")")
    }
  }

  func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
    guard error == nil, characteristic.uuid == Self.hrMeasurement, let value = characteristic.value else { return }
    delegate?.central(id: peripheral.identifier.uuidString, didReceive: value)
  }
}
