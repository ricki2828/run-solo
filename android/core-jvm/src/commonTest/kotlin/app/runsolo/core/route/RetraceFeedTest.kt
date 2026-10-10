package app.runsolo.core.route

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull
import kotlin.test.assertTrue

class RetraceFeedTest {
    private class Fix(
        val lat: Double,
        val lon: Double,
        val acc: Double,
        val elev: Double?,
        val baro: Boolean,
        val dist: Double,
        val active: Boolean,
    )

    private fun feed(f: RetraceFeed, fixes: List<Fix>) {
        for (x in fixes) f.offer(x.lat, x.lon, x.acc, x.elev, x.baro, x.dist, x.active)
    }

    /** 600 m out and back, a fix every 3 m; the runner stands at the turn for 20 jittery, auto-paused fixes. */
    private fun outAndBack(): List<Fix> {
        val fixes = ArrayList<Fix>()
        var dist = 0.0
        fun at(north: Double, east: Double, active: Boolean, acc: Double = 8.0) {
            fixes.add(Fix(north / 111_320.0, east / 111_320.0, acc, north * 0.05, true, dist, active))
        }
        var m = 0.0
        while (m <= 600) { at(m, 0.0, true); m += 3; dist += 3 }
        for (i in 0 until 20) at(600.0 + (i % 5) * 9.0 - 18.0, (i % 3) * 7.0 - 7.0, false) // the junction jitter
        m = 600.0
        while (m >= 0) { at(m, 4.0, true); m -= 3; dist += 3 }
        return fixes
    }

    @Test
    fun `a fix while auto-paused or with poor accuracy is not used`() {
        val f = RetraceFeed()
        assertNull(f.offer(0.0, 0.0, 8.0, 1.0, true, 0.0, active = false))
        assertNull(f.offer(0.0, 0.0, 40.0, 1.0, true, 0.0, active = true))
        assertEquals(0, f.detector.length)
        assertTrue(f.offer(0.0, 0.0, 8.0, 1.0, true, 0.0, active = true) != null)
        assertEquals(1, f.detector.length)
    }

    @Test
    fun `junction jitter during an auto-pause adds no track`() {
        val fixes = outAndBack()
        val f = RetraceFeed()
        feed(f, fixes)
        val withoutJitter = RetraceFeed()
        feed(withoutJitter, fixes.filter { it.active })
        assertEquals(withoutJitter.detector.length, f.detector.length)
        assertEquals(withoutJitter.state, f.state)
    }

    @Test
    fun `no barometer means no height and no climb, whatever GPS altitude says`() {
        val f = RetraceFeed()
        feed(f, outAndBack().map { Fix(it.lat, it.lon, it.acc, it.elev, false, it.dist, it.active) })
        val s = f.state
        assertNull(s.heightVsStartM)
        assertNull(s.climbAheadM)
        assertNull(s.descentAheadM)
    }

    @Test
    fun `restoring mid-retrace rebuilds the same answer as running straight through`() {
        val fixes = outAndBack()
        val straight = RetraceFeed()
        feed(straight, fixes)
        // Kill 160 m into the way back: everything so far is rebuilt from the journal (the same
        // fixes, the same distances), then the run carries on.
        val killAt = fixes.indexOfFirst { it.active && it.dist >= 760.0 }
        assertTrue(killAt > 0)
        val restored = RetraceFeed()
        feed(restored, fixes.subList(0, killAt))
        // The restore path IS this call sequence: nothing the live path does is skipped.
        feed(restored, fixes.subList(killAt, fixes.size))
        assertEquals(straight.state, restored.state)
        assertTrue(restored.state.retracing)
        assertEquals(RetraceDirection.reverse, restored.state.direction)
        // And a restore that replays the first part again from a fresh detector agrees mid-run too.
        val a = RetraceFeed()
        val b = RetraceFeed()
        feed(a, fixes.subList(0, killAt))
        feed(b, fixes.subList(0, killAt))
        assertEquals(a.state, b.state)
        assertTrue(a.state.retracing, "160 m into the way back it is already retracing")
    }
}
