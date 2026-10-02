package app.runsolo.core.record

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class LiveRouteTest {
    // About 1.11 m per 0.00001 degrees of latitude.
    private fun lat(metres: Double) = -33.0 + metres / 111_320.0

    @Test
    fun `fixes closer than the step are dropped and the first always counts`() {
        val r = LiveRoute(minStepM = 4.0)
        assertTrue(r.offer(lat(0.0), 151.0, 5.0))
        assertFalse(r.offer(lat(2.0), 151.0, 5.0))
        assertTrue(r.offer(lat(5.0), 151.0, 5.0))
        assertEquals(2, r.size)
    }

    @Test
    fun `a poor fix never becomes a point`() {
        val r = LiveRoute(maxAccuracyM = 25.0)
        assertFalse(r.offer(lat(0.0), 151.0, 40.0))
        assertEquals(0, r.size)
    }

    @Test
    fun `since returns the flat tail from an index and nothing past the end`() {
        val r = LiveRoute(minStepM = 1.0)
        r.offer(lat(0.0), 151.0, 5.0)
        r.offer(lat(10.0), 151.0, 5.0)
        r.offer(lat(20.0), 151.0, 5.0)
        assertEquals(6, r.since(0).size)
        assertEquals(listOf(lat(20.0), 151.0), r.since(2))
        assertTrue(r.since(3).isEmpty())
        assertEquals(6, r.since(-4).size)
    }
}
