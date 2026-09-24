package app.runsolo.core.ble

import app.runsolo.core.model.HrReading
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertIs
import kotlin.test.assertNull
import kotlin.test.assertTrue

class BleTest {
    private fun b(vararg v: Int) = ByteArray(v.size) { v[it].toByte() }

    @Test
    fun `hr - 8 bit value`() {
        val p = HeartRateMeasurement.parse(b(0x00, 0x96))!!
        assertEquals(150, p.bpm)
        assertFalse(p.sixteenBit)
        assertFalse(p.contactSupported)
    }

    @Test
    fun `hr - 16 bit value little endian`() {
        val p = HeartRateMeasurement.parse(b(0x01, 0x2C, 0x01))!!
        assertEquals(300, p.bpm)
        assertTrue(p.sixteenBit)
        assertNull(HeartRateMeasurement.parse(b(0x01, 0x2C)), "16-bit flag with only one value byte")
    }

    @Test
    fun `hr - sensor contact bits`() {
        // Supported + detected (0b110) → value kept.
        assertEquals(72, HeartRateMeasurement.bpmOrNull(b(0x06, 0x48)))
        // Supported, not detected (0b100) → null even though the strap sends a number.
        val p = HeapRate(b(0x04, 0x48))
        assertNull(p.bpm)
        assertEquals(72, p.rawBpm)
        assertTrue(p.contactSupported && !p.contactDetected)
        // Not supported (bit2 clear) with bit1 set is meaningless → value kept.
        assertEquals(72, HeartRateMeasurement.bpmOrNull(b(0x02, 0x48)))
    }

    private fun HeapRate(bytes: ByteArray) = HeartRateMeasurement.parse(bytes)!!

    @Test
    fun `hr - zero bpm is null, never 0`() {
        assertNull(HeartRateMeasurement.bpmOrNull(b(0x00, 0x00)))
        assertNull(HeartRateMeasurement.bpmOrNull(b(0x01, 0x00, 0x00)))
    }

    @Test
    fun `hr - RR intervals are ignored and energy expended is read`() {
        // flags: 16-bit | contact supported+detected | energy | RR = 0b00011111
        val p = HeartRateMeasurement.parse(b(0x1F, 0x8C, 0x00, 0x10, 0x27, 0x34, 0x03, 0x50, 0x03))!!
        assertEquals(140, p.bpm)
        assertEquals(10_000, p.energyExpendedKj)
        // Same with RR only (no energy): the RR bytes must not be mistaken for energy.
        val q = HeartRateMeasurement.parse(b(0x10, 0x8C, 0x34, 0x03))!!
        assertEquals(140, q.bpm)
        assertNull(q.energyExpendedKj)
    }

    @Test
    fun `hr - short packets`() {
        assertNull(HeartRateMeasurement.parse(ByteArray(0)))
        assertNull(HeartRateMeasurement.parse(b(0x00)))
    }

    @Test
    fun `join - latest reading within 2 s else null`() {
        val j = HrJoin()
        assertNull(j.hrAt(0))
        j.offer(HrReading(10_000, 150))
        assertEquals(150, j.hrAt(10_000))
        assertEquals(150, j.hrAt(12_000))
        assertNull(j.hrAt(12_001))
        assertNull(j.hrAt(9_000), "a reading from the future is not used")
        j.offer(HrReading(13_000, 151))
        assertEquals(151, j.hrAt(13_500))
        j.disconnected()
        assertNull(j.hrAt(13_500))
    }

    @Test
    fun `reconnect - pair is direct, drops reconnect by saved address with backoff, never rescan`() {
        val p = BleReconnectPolicy(null)
        assertIs<BleReconnectPolicy.Action.Nothing>(p.onStart())
        assertIs<BleReconnectPolicy.Action.Nothing>(p.onDisconnected(0))
        val pair = p.pair("AA:BB")
        assertEquals(BleReconnectPolicy.Action.Reconnect("AA:BB", autoConnect = false, delayMs = 0, closeFirst = true), pair)
        assertEquals(BleReconnectPolicy.Action.Reconnect("AA:BB", autoConnect = true, delayMs = 0, closeFirst = true), p.onStart())
        p.onConnected(1_000)
        // Drops after 2 s (unstable): 1 s, 2 s, 4 s … capped at 30 s.
        val delays = (1..7).map { (p.onDisconnected(3_000) as BleReconnectPolicy.Action.Reconnect).delayMs }
        assertEquals(listOf(1_000L, 2_000L, 4_000L, 8_000L, 16_000L, 30_000L, 30_000L), delays)
        assertEquals(7, p.attempts)
        // A link that held for 10 s resets the backoff.
        p.onConnected(100_000)
        val r = p.onDisconnected(110_000) as BleReconnectPolicy.Action.Reconnect
        assertEquals(1_000, r.delayMs)
        assertTrue(r.autoConnect && r.closeFirst)
        assertEquals(1, p.attempts)
        p.forget()
        assertNull(p.savedAddress)
        assertIs<BleReconnectPolicy.Action.Nothing>(p.onConnectFailed(0))
    }
}
