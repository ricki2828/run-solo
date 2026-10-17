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
    fun `hr - zero bpm is null never 0`() {
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
    fun `join - nearest reading within plus or minus 2 s else null`() {
        val j = HrJoin()
        assertNull(j.hrAt(0))
        j.offer(HrReading(10_000, 150))
        assertEquals(150, j.hrAt(10_000))
        assertEquals(150, j.hrAt(12_000))
        assertNull(j.hrAt(12_001))
        // A fix stamped with its fix time is delivered later than the strap's next notification:
        // the reading 400 ms AFTER the sample time still joins.
        assertEquals(150, j.hrAt(9_600))
        assertNull(j.hrAt(7_999))
        j.offer(HrReading(13_000, 151))
        assertEquals(150, j.hrAt(11_400), "nearest wins, not newest")
        assertEquals(151, j.hrAt(12_600))
        j.offerNoContact()
        assertNull(j.hrAt(13_000), "no-contact clears the stale value")
        j.offer(HrReading(14_000, 152))
        j.disconnected()
        assertNull(j.hrAt(14_000))
    }

    private fun cand(addr: String, name: String?, rssi: Int = -60) = BleReconnectPolicy.Candidate(addr, name, rssi)

    private fun fastHunt(passive: String, delayMs: Long = 0) =
        BleReconnectPolicy.Action.Hunt(delayMs, BleReconnectPolicy.FAST_SCAN_MS, passive, lowLatency = true)

    @Test
    fun `reconnect - pairing connects directly - every other connect starts with a hunt`() {
        val p = BleReconnectPolicy(null)
        assertIs<BleReconnectPolicy.Action.Nothing>(p.onStart(0), "nothing paired: nothing to hunt")
        assertIs<BleReconnectPolicy.Action.Nothing>(p.onDisconnected(0))
        assertEquals(BleReconnectPolicy.Action.Connect("AA:BB", delayMs = 0), p.pair("AA:BB", "WHOOP 4A0934"))
        assertEquals(BleReconnectPolicy.LinkState.CONNECTING, p.state)
        assertIs<BleReconnectPolicy.Action.Nothing>(p.onStart(1_000), "already connecting: carry on")
        p.onConnected(2_000)
        assertIs<BleReconnectPolicy.Action.Nothing>(p.onStart(3_000), "already connected: carry on")
        p.stop()
        assertEquals(BleReconnectPolicy.LinkState.IDLE, p.state)
        // The next session (Start/Ready on screen, or a run) hunts: the saved address may be stale.
        assertEquals(fastHunt("AA:BB"), p.onStart(100_000))
        assertEquals(BleReconnectPolicy.LinkState.HUNTING, p.state)
        p.forget()
        assertNull(p.savedAddress)
        assertIs<BleReconnectPolicy.Action.Nothing>(p.onStart(200_000))
        assertIs<BleReconnectPolicy.Action.Nothing>(p.onConnectFailed(200_000))
    }

    @Test
    fun `hunt - stale rotating address is found by name and the saved address follows it`() {
        // Ricki 17-Oct: WHOOP broadcast from a new private address; the saved one is stale.
        val p = BleReconnectPolicy("OLD", "WHOOP 4A0934")
        p.onStart(0)
        assertIs<BleReconnectPolicy.Action.Nothing>(p.onScanResult(cand("X1", "Polar H10", -40), 500), "another strap is never taken")
        val r = p.onScanResult(cand("NEW", "whoop 4a0934", -70), 900)
        assertEquals(BleReconnectPolicy.Action.Connect("NEW", delayMs = 0), r)
        assertEquals("NEW", p.savedAddress)
        assertEquals(BleReconnectPolicy.Match.NAME, p.lastMatch)
        assertEquals(BleReconnectPolicy.LinkState.CONNECTING, p.state)
        assertIs<BleReconnectPolicy.Action.Nothing>(p.onScanResult(cand("NEW2", "WHOOP 4A0934"), 1_000), "results after a match are ignored")
        p.onConnected(2_000)
        assertEquals(BleReconnectPolicy.LinkState.CONNECTED, p.state)
    }

    @Test
    fun `hunt - the saved address seen by the scan is connected directly`() {
        val p = BleReconnectPolicy("AA", "Polar H10 1234")
        p.onStart(0)
        assertEquals(BleReconnectPolicy.Action.Connect("AA", delayMs = 0), p.onScanResult(cand("AA", null), 300))
        assertEquals(BleReconnectPolicy.Match.ADDRESS, p.lastMatch)
    }

    @Test
    fun `hunt - the passive connect coming up ends the hunt`() {
        val p = BleReconnectPolicy("AA", "Polar H10 1234")
        p.onStart(0)
        assertIs<BleReconnectPolicy.Action.Nothing>(p.onDisconnected(1_000), "the passive connect giving up: the scan carries on")
        assertEquals(BleReconnectPolicy.LinkState.HUNTING, p.state)
        p.onLinkUp()
        assertEquals(BleReconnectPolicy.LinkState.CONNECTING, p.state)
        assertIs<BleReconnectPolicy.Action.Nothing>(p.onScanResult(cand("AA", "Polar H10 1234"), 2_000))
    }

    @Test
    fun `hunt - a strap of the same brand from another runner is never taken - even alone`() {
        // Parkrun start: ours is not broadcasting yet, a stranger's WHOOP is.
        val p = BleReconnectPolicy("OLD", "WHOOP 4A0934")
        p.onStart(0)
        assertIs<BleReconnectPolicy.Action.Nothing>(p.onScanResult(cand("N1", "WHOOP 4C1111", -40), 500))
        assertIs<BleReconnectPolicy.Action.Nothing>(p.onHuntTick(60_000))
        assertIs<BleReconnectPolicy.Action.Nothing>(p.onScanResult(cand("N2", "WHOOP 4D2222"), 61_000))
        assertEquals(BleReconnectPolicy.LinkState.HUNTING, p.state)
        assertEquals("OLD", p.savedAddress)
        assertEquals("WHOOP 4A0934", p.savedName)
        // Ours turns up later in the same hunt: it is taken, not the stronger stranger.
        assertEquals(BleReconnectPolicy.Action.Connect("NEW", delayMs = 0), p.onScanResult(cand("NEW", "WHOOP 4A0934", -80), 62_000))
    }

    @Test
    fun `hunt - without a saved name only the saved address matches`() {
        val p = BleReconnectPolicy("OLD", null)
        p.onStart(0)
        assertIs<BleReconnectPolicy.Action.Nothing>(p.onScanResult(cand("NEW", "WHOOP 4A0934"), 500))
        assertIs<BleReconnectPolicy.Action.Nothing>(p.onHuntTick(60_000))
        assertEquals(BleReconnectPolicy.Action.Connect("OLD", delayMs = 0), p.onScanResult(cand("OLD", null), 61_000))
    }

    @Test
    fun `hunt - a scan that ends without a match hunts again - never gives up`() {
        val p = BleReconnectPolicy("OLD", "WHOOP 4A0934")
        assertEquals(fastHunt("OLD"), p.onStart(0))
        // The strap's broadcast was still off: the next scan starts straight away.
        assertEquals(fastHunt("OLD"), p.onScanEnded(BleReconnectPolicy.FAST_SCAN_MS, failed = false))
        // After the fast hunts, it keeps looking at the balanced rate.
        val slow = p.onScanEnded(2 * BleReconnectPolicy.FAST_SCAN_MS, failed = false) as BleReconnectPolicy.Action.Hunt
        assertEquals(BleReconnectPolicy.HUNT_SCAN_MS, slow.scanMs)
        assertFalse(slow.lowLatency)
        assertEquals(0, slow.delayMs)
        // Broadcast turned on: the strap is found on the next result.
        assertIs<BleReconnectPolicy.Action.Connect>(p.onScanResult(cand("NEW", "WHOOP 4A0934"), 130_000))
        // A failed scan (e.g. throttled by the OS) retries after the backoff, not instantly.
        val q = BleReconnectPolicy("OLD", "WHOOP 4A0934")
        q.onStart(0)
        assertEquals(500, (q.onScanEnded(1_000, failed = true) as BleReconnectPolicy.Action.Hunt).delayMs)
    }

    @Test
    fun `reconnect - drops hunt again with backoff - a stable link resets it`() {
        val p = BleReconnectPolicy("A", "WHOOP 1")
        p.onStart(0)
        p.onScanResult(cand("A", "WHOOP 1"), 1)
        p.onConnected(1_000)
        val delays = (1..6).map { i ->
            val t = i * 100_000L
            val h = p.onConnectFailed(t) as BleReconnectPolicy.Action.Hunt
            assertEquals("A", h.passiveAddress)
            assertIs<BleReconnectPolicy.Action.Connect>(p.onScanResult(cand("A", "WHOOP 1"), t + 1))
            h.delayMs
        }
        assertEquals(listOf(500L, 1_000L, 2_000L, 4_000L, 8_000L, 8_000L), delays)
        p.onConnected(1_000_000)
        val r = p.onDisconnected(1_010_000) as BleReconnectPolicy.Action.Hunt
        assertEquals(500, r.delayMs)
        assertEquals(1, p.attempts)
        assertTrue(r.lowLatency, "a drop after a working link looks fast again")
    }

    @Test
    fun `budget - a hunt over the scan-start budget is delayed - never dropped`() {
        val p = BleReconnectPolicy("OLD", "WHOOP 4A0934")
        repeat(BleReconnectPolicy.SCAN_STARTS_PER_WINDOW) { p.noteScanStart(1_000L + it) }
        assertFalse(p.canStartScan(10_000))
        val h = p.onStart(10_000) as BleReconnectPolicy.Action.Hunt
        assertEquals(1_000L + BleReconnectPolicy.SCAN_WINDOW_MS - 10_000, h.delayMs)
        assertFalse(p.canStartScan(10_000), "the planned hunt holds a slot too")
        assertTrue(p.canStartScan(80_000))
    }
}
