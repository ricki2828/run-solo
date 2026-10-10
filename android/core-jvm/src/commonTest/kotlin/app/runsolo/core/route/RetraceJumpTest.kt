package app.runsolo.core.route

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

class RetraceJumpTest {
    private val mPerDeg = 111_320.0

    @Test
    fun `a 500 km GPS jump does not grow the index or run out of memory`() {
        val d = RetraceDetector()
        for (i in 0..100) d.add(i * 3 / mPerDeg, 0.0, null)
        val before = d.indexedCellCount
        // The recorder crash: one fix 500 km away used to list a segment in millions of cells.
        val s = d.add(4.5, 0.0, null)
        assertEquals(before, d.indexedCellCount, "the jump segment is not indexed")
        assertFalse(s.retracing)
        assertTrue(d.trackLengthM < 400.0, "the jump added no along-track distance: ${d.trackLengthM}")
        for (i in 1..100) d.add(4.5 + i * 3 / mPerDeg, 0.0, null)
        assertTrue(d.indexedCellCount < before + 40, "cells after: ${d.indexedCellCount}")
        // Jump back onto the first line and run it in reverse: still recognised.
        var back = d.state
        var m = 300.0
        while (m >= 100.0) { back = d.add(m / mPerDeg, 4 / mPerDeg, null); m -= 3.0 }
        assertTrue(back.retracing)
        assertEquals(RetraceDirection.reverse, back.direction)
    }

    @Test
    fun `any segment box over the cell cap is not indexed`() {
        // 140 m steps (under the jump cap) with a 25 m radius touch a handful of cells, never millions.
        val d = RetraceDetector()
        for (i in 0..50) d.add(i * 140 / mPerDeg, 0.0, null)
        assertTrue(d.indexedCellCount < 51 * 40)
    }

    private class Exploding : RetraceDetector() {
        override fun add(lat: Double, lon: Double, elevM: Double?, distM: Double?): RetraceState =
            throw IllegalStateException("boom")
    }

    @Test
    fun `a failure in the detector disables retrace and the feed never throws`() {
        var reported: Throwable? = null
        val f = RetraceFeed(Exploding(), onFailure = { reported = it })
        assertNull(f.offer(0.0, 0.0, 5.0, null, false, 0.0, active = true))
        assertNotNull(f.failure)
        assertNotNull(reported)
        // Later fixes are ignored, the failure is reported once, and the state reads as none.
        reported = null
        assertNull(f.offer(0.0, 0.0, 5.0, null, false, 3.0, active = true))
        assertNull(reported)
        assertEquals(RetraceState.NONE, f.state)
    }

    private class OutOfMemory : RetraceDetector() {
        override fun add(lat: Double, lon: Double, elevM: Double?, distM: Double?): RetraceState =
            throw OutOfMemoryError("test")
    }

    @Test
    fun `even an OutOfMemoryError in the detector does not escape the feed`() {
        val f = RetraceFeed(OutOfMemory())
        assertNull(f.offer(0.0, 0.0, 5.0, null, false, 0.0, active = true))
        assertTrue(f.failure is OutOfMemoryError)
    }
}
