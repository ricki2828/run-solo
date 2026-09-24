package app.runsolo.core.gps

import app.runsolo.core.model.LocationFix
import app.runsolo.core.replay.TraceFixture
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

class GpsTest {
    @Test
    fun `haversine - known distances`() {
        // Sydney Opera House → Harbour Bridge (south pylon) ≈ 1.0 km; equator degree ≈ 111.2 km.
        assertEquals(0.0, Geo.haversineM(-33.8568, 151.2153, -33.8568, 151.2153))
        assertEquals(111_195.0, Geo.haversineM(0.0, 0.0, 0.0, 1.0), 20.0)
        assertEquals(111_195.0, Geo.haversineM(0.0, 0.0, 1.0, 0.0), 20.0)
        val d = Geo.haversineM(-33.8568, 151.2153, -33.8523, 151.2108)
        assertTrue(d in 600.0..700.0, "got $d")
    }

    @Test
    fun `filter - accuracy gate, speed sanity, monotonic time`() {
        val f = PointFilter()
        val first = f.offer(LocationFix(0, 0.0, 0.0, null, 10.0, null))
        assertFalse(first.accepted)
        assertEquals(PointFilter.Reason.awaitingConfirmation, first.reason)
        val second = f.offer(LocationFix(1000, 0.0, 0.00003, null, 10.0, null)) // 3.3 m/s agrees → anchored
        assertTrue(second.accepted)
        assertEquals(3.3, second.totalM, 0.1)
        val bad = f.offer(LocationFix(2000, 0.0, 0.0001, null, 26.0, null))
        assertFalse(bad.accepted)
        assertEquals(PointFilter.Reason.accuracy, bad.reason)
        // 0.0001° ≈ 11.1 m from the anchor in 1 s → 7.8 m/s → rejected as a spike.
        val spike = f.offer(LocationFix(2000, 0.0, 0.0001, null, 5.0, null))
        assertEquals(PointFilter.Reason.speed, spike.reason)
        // Same point 3 s after the anchor: 2.6 m/s → accepted, distance measured from the LAST ACCEPTED point.
        val ok = f.offer(LocationFix(4000, 0.0, 0.0001, null, 5.0, null))
        assertTrue(ok.accepted)
        assertEquals(11.1, ok.totalM, 0.1)
        val back = f.offer(LocationFix(3500, 0.0, 0.0002, null, 5.0, null))
        assertEquals(PointFilter.Reason.notMonotonic, back.reason)
        assertEquals(3, f.acceptedCount)
        assertEquals(4, f.rejectedCount)
        assertEquals(11.1, f.totalM, 0.1)
    }

    @Test
    fun `filter - synthetic straight line measures its ground truth`() {
        val f = PointFilter()
        for (fix in TraceFixture.straightLine(listOf(240 to 4.0, 180 to 2.0))) f.offer(fix)
        assertEquals(240 * 4.0 + 180 * 2.0, f.totalM, 2.0)
        assertEquals(1, f.rejectedCount, "only the unconfirmed first point")
        assertEquals(0, f.reanchors)
    }

    @Test
    fun `filter - a bad first fix 400 m away is not the anchor`() {
        val f = PointFilter()
        val line = TraceFixture.straightLine(listOf(60 to 3.0), startT = 1000)
        f.offer(LocationFix(0, line[0].lat + 0.0036, line[0].lon, null, 12.0, null)) // stale cold-start blend, 400 m north
        for (fix in line) f.offer(fix)
        assertEquals(60 * 3.0, f.totalM, 1.0)
        assertEquals(0, f.reanchors)
    }

    @Test
    fun `filter - three agreeing rejections re-anchor without counting the jump`() {
        val f = PointFilter()
        val here = TraceFixture.straightLine(listOf(10 to 3.0))
        for (fix in here) f.offer(fix)
        val before = f.totalM
        // The track jumps 300 m east (a tunnel exit with a stale anchor) and continues at 3 m/s.
        val there = TraceFixture.straightLine(listOf(10 to 3.0), lon0 = here.last().lon + 300 / 92_000.0, startT = here.last().t + 1000)
        for (fix in there) f.offer(fix)
        assertEquals(1, f.reanchors)
        assertEquals(before + 8 * 3.0, f.totalM, 1.0) // 11 fixes over there: 3 spent confirming, 8 steps counted, the 300 m jump never
    }

    @Test
    fun `moving detector - starts, stops after hysteresis, counts moving time`() {
        val m = MovingDetector()
        var d = 0.0
        var t = 0L
        repeat(20) { t += 1000; d += 3.0; m.update(t, d) }
        assertTrue(m.moving)
        // Standing at a kerb: 4 s below threshold is not a stop yet, 6 s is.
        repeat(4) { t += 1000; m.update(t, d) }
        assertTrue(m.moving)
        repeat(3) { t += 1000; m.update(t, d) }
        assertFalse(m.moving)
        val movingBefore = m.movingMs
        repeat(10) { t += 1000; m.update(t, d) }
        assertEquals(movingBefore, m.movingMs, "stopped time does not count")
        t += 1000; d += 3.0; m.update(t, d)
        assertFalse(m.moving, "one fast step is a wobble")
        t += 1000; d += 3.0; m.update(t, d)
        assertTrue(m.moving)
        // GPS drift while standing (0.3 m/s) never starts it.
        val still = MovingDetector()
        var dd = 0.0
        for (s in 1..30) { dd += 0.3; still.update(s * 1000L, dd) }
        assertFalse(still.moving)
    }

    @Test
    fun `live pace - seconds per km over 15 s window`() {
        val p = LivePace()
        assertNull(p.update(0, 0.0))
        var d = 0.0
        var last: Double? = null
        for (s in 1..30) { d += 4.0; last = p.update(s * 1000L, d) } // 4 m/s = 250 s/km
        assertEquals(250.0, last!!, 0.5)
        for (s in 31..60) { d += 2.0; last = p.update(s * 1000L, d) } // 2 m/s = 500 s/km
        assertEquals(500.0, last!!, 0.5)
        p.reset()
        assertNull(p.update(61_000, d))
    }
}
