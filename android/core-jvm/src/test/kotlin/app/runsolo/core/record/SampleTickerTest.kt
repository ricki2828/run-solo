package app.runsolo.core.record

import app.runsolo.core.model.HrReading
import app.runsolo.core.model.LocationFix
import app.runsolo.core.replay.TraceFixture
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

class SampleTickerTest {
    private fun fix(t: Long, east: Double = 0.0) = LocationFix(t, -33.8688, 151.2093 + east / 92_000.0, 10.0, 6.0, 3.0)

    @Test
    fun `tick with a fix journals the fix, without one journals a no-fix tick with HR`() {
        val ticker = SampleTicker(wall = { 42 })
        ticker.onHr(HrReading(900, 150))
        ticker.onFix(fix(1000))
        val s1 = ticker.tick(1005).single()
        assertTrue(s1.hasFix)
        assertEquals(1000, s1.t)
        assertEquals(150, s1.hr)
        assertEquals(42, s1.w)
        ticker.onHr(HrReading(1900, 151))
        val s2 = ticker.tick(2005).single()
        assertFalse(s2.hasFix)
        assertEquals(2005, s2.t)
        assertEquals(151, s2.hr)
        assertNull(ticker.tick(5000).single().hr, "HR older than 2 s is not carried")
        assertTrue(ticker.gpsLost(7000))
        assertFalse(ticker.gpsLost(2000))
    }

    @Test
    fun `a late fix stamped before a journaled no-fix tick is re-stamped after it`() {
        val ticker = SampleTicker(wall = { 0 })
        ticker.onFix(fix(1000))
        ticker.tick(1010)
        val noFix = ticker.tick(2010).single() // provider silent this second
        assertEquals(2010, noFix.t)
        ticker.onFix(fix(1990, east = 3.0)) // arrives 900 ms late, stamped before the no-fix tick
        val late = ticker.tick(3010).single()
        assertTrue(late.hasFix)
        assertEquals(2011, late.t, "journal order stays time order")
        assertEquals(1, ticker.restamped)
        ticker.onFix(fix(2990, east = 6.0))
        assertEquals(2990, ticker.tick(4010).single().t)
    }

    @Test
    fun `two fixes in one tick are both journaled in fix-time order`() {
        val ticker = SampleTicker(wall = { 0 })
        ticker.onFix(fix(1400, east = 1.0))
        ticker.onFix(fix(1000))
        val s = ticker.tick(1500)
        assertEquals(listOf(1000L, 1400L), s.map { it.t })
        ticker.onFix(fix(2400, east = 4.0))
        ticker.tick(2500)
        assertEquals(4.0, ticker.distanceM, 0.2) // anchor at 1000 confirmed by 1400, then 1400 → 2400
    }

    @Test
    fun `paused - fixes still journaled, distance frozen, re-anchored on resume`() {
        val ticker = SampleTicker(wall = { 0 })
        var t = 0L
        var east = 0.0
        fun step(mps: Double) { t += 1000; east += mps; ticker.onFix(fix(t, east)); ticker.tick(t + 50) }
        repeat(10) { step(3.0) }
        val before = ticker.distanceM
        ticker.onPause()
        repeat(5) { step(2.0) } // walking to the tap
        assertEquals(before, ticker.distanceM)
        assertTrue(ticker.paused)
        ticker.onResume()
        repeat(10) { step(3.0) }
        assertEquals(before + 9 * 3.0, ticker.distanceM, 0.5) // the 10 m walked never counts; one fix re-anchors
    }

    @Test
    fun `jittered late delivery over a straight line - every fix journaled in order, ground-truth distance`() {
        val ticker = SampleTicker(wall = { 0 })
        val fixes = TraceFixture.straightLine(listOf(120 to 3.0), startT = 10_000)
        val samples = ArrayList<app.runsolo.core.journal.JournalLine.Sample>()
        var pendingLate: LocationFix? = null
        for ((i, f) in fixes.withIndex()) {
            // Every 7th fix is delivered ~1.2 s late (after the next tick already ran).
            pendingLate?.let { ticker.onFix(it); pendingLate = null }
            if (i % 7 == 3) pendingLate = f else ticker.onFix(f)
            samples.addAll(ticker.tick(f.t + 150))
        }
        pendingLate?.let { ticker.onFix(it) }
        samples.addAll(ticker.tick(fixes.last().t + 1150))
        assertTrue(samples.zipWithNext().all { (a, b) -> b.t > a.t }, "strictly increasing t")
        assertEquals(fixes.size, samples.count { it.hasFix })
        assertEquals(357.0, ticker.distanceM, 3.0) // anchored at the second fix
        assertTrue(ticker.restamped > 0)
    }
}
