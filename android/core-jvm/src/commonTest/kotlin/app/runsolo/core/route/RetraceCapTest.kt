package app.runsolo.core.route

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

class RetraceCapTest {
    @Test
    fun `past the point cap a retrace is cleared, not frozen`() {
        val d = RetraceDetector()
        val mPerDeg = 111_320.0
        var s = RetraceState.NONE
        for (i in 0 until 19_900) s = d.add(i * 3 / mPerDeg, 0.0, 100.0)
        var retracingBeforeCap = false
        var back = 0
        while (d.length < RetraceDetector.MAX_POINTS) {
            s = d.add((19_899 - back) * 3 / mPerDeg, 4 / mPerDeg, 100.0 + back * 0.1)
            back++
            if (s.retracing) retracingBeforeCap = true
        }
        assertTrue(retracingBeforeCap, "the way back was recognised before the cap")
        assertEquals(RetraceDetector.MAX_POINTS, d.length)
        for (i in 0 until 5) {
            s = d.add((19_899 - back) * 3 / mPerDeg, 4 / mPerDeg, 100.0 + back * 0.1)
            back++
        }
        assertFalse(s.retracing)
        assertNull(s.direction)
        assertNull(s.distanceToStartM)
        assertNull(s.climbAheadM)
        assertNull(s.descentAheadM)
        assertEquals(RetraceDetector.MAX_POINTS, d.length)
    }
}
