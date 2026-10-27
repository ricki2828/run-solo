import Foundation

/// Bluetooth SIG Heart Rate Measurement characteristic (0x2A37) parser. Swift twin of the Kotlin
/// `HeartRateMeasurement` (android/core-jvm .../core/ble); `RunnerTests/Resources/ble-hr-vectors.json`
/// holds the shared byte vectors and `tools/check_ble_vectors.py` keeps it in step with `BleTest.kt`.
///
/// Flags byte: bit0 = 16-bit value, bit1 = sensor contact detected, bit2 = sensor contact supported,
/// bit3 = energy expended present, bit4 = RR intervals present.
/// `bpm` is nil when the strap reports no sensor contact (supported but not detected) or 0 bpm:
/// the recorder journals no HR then, never 0.
///
/// Beyond Kotlin: RR intervals are parsed (`rrRaw`, 1/1024 s units). Nothing consumes them yet;
/// the Kotlin parser ignores them.
struct HeartRateMeasurement: Equatable {
  let bpm: Int?
  let rawBpm: Int
  let sixteenBit: Bool
  let contactSupported: Bool
  let contactDetected: Bool
  let energyExpendedKj: Int?
  let rrRaw: [Int]

  /// RR intervals in milliseconds.
  var rrMs: [Double] { rrRaw.map { Double($0) * 1000.0 / 1024.0 } }

  /// nil for a packet too short to hold the flags and the value.
  static func parse(_ data: Data) -> HeartRateMeasurement? {
    let bytes = [UInt8](data)
    guard let first = bytes.first else { return nil }
    let flags = Int(first)
    let sixteen = flags & 0x01 != 0
    let contactSupported = flags & 0x04 != 0
    let contactDetected = flags & 0x02 != 0
    let energyPresent = flags & 0x08 != 0
    let rrPresent = flags & 0x10 != 0
    var i = 1
    let raw: Int
    if sixteen {
      guard bytes.count >= 3 else { return nil }
      raw = Int(bytes[1]) | (Int(bytes[2]) << 8)
      i = 3
    } else {
      guard bytes.count >= 2 else { return nil }
      raw = Int(bytes[1])
      i = 2
    }
    var energy: Int?
    if energyPresent {
      if bytes.count >= i + 2 { energy = Int(bytes[i]) | (Int(bytes[i + 1]) << 8) }
      i += 2
    }
    var rr: [Int] = []
    if rrPresent {
      while i + 1 < bytes.count {
        rr.append(Int(bytes[i]) | (Int(bytes[i + 1]) << 8))
        i += 2
      }
    }
    let noContact = contactSupported && !contactDetected
    return HeartRateMeasurement(
      bpm: (noContact || raw == 0) ? nil : raw, rawBpm: raw, sixteenBit: sixteen,
      contactSupported: contactSupported, contactDetected: contactDetected,
      energyExpendedKj: energy, rrRaw: rr)
  }
}
