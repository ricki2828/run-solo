package app.runsolo.core.ble

/**
 * Bluetooth SIG Heart Rate Measurement characteristic (0x2A37) parser.
 *
 * Flags byte: bit0 = 16-bit value, bits1–2 = sensor contact (bit2 supported, bit1 detected),
 * bit3 = energy expended present, bit4 = RR intervals present. RR intervals are ignored.
 * [bpm] is null when the strap reports no sensor contact (contact supported but not
 * detected) or a 0 bpm value — the recorder journals `hr=null`, never 0 (plan §3, W7).
 */
object HeartRateMeasurement {
    data class Parsed(
        val bpm: Int?,
        val rawBpm: Int,
        val sixteenBit: Boolean,
        val contactSupported: Boolean,
        val contactDetected: Boolean,
        val energyExpendedKj: Int?,
    )

    /** Returns null for a packet too short to hold the flags and value. */
    fun parse(bytes: ByteArray): Parsed? {
        if (bytes.isEmpty()) return null
        val flags = bytes[0].toInt() and 0xFF
        val sixteen = flags and 0x01 != 0
        val contactSupported = flags and 0x04 != 0
        val contactDetected = flags and 0x02 != 0
        val energyPresent = flags and 0x08 != 0
        var i = 1
        val raw: Int
        if (sixteen) {
            if (bytes.size < 3) return null
            raw = (bytes[1].toInt() and 0xFF) or ((bytes[2].toInt() and 0xFF) shl 8)
            i = 3
        } else {
            if (bytes.size < 2) return null
            raw = bytes[1].toInt() and 0xFF
            i = 2
        }
        var energy: Int? = null
        if (energyPresent && bytes.size >= i + 2) {
            energy = (bytes[i].toInt() and 0xFF) or ((bytes[i + 1].toInt() and 0xFF) shl 8)
        }
        val noContact = contactSupported && !contactDetected
        val bpm = if (noContact || raw == 0) null else raw
        return Parsed(bpm, raw, sixteen, contactSupported, contactDetected, energy)
    }

    /** Convenience for the service: bpm or null, in one call. */
    fun bpmOrNull(bytes: ByteArray): Int? = parse(bytes)?.bpm
}
