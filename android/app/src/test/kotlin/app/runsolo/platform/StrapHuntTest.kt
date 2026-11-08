package app.runsolo.platform

import android.content.Context
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.annotation.Config

/**
 * The saved HR strap is its own want on Start/Ready (Ricki's treadmill run, 8-Nov): #336 tied it to the GPS probe, so a
 * treadmill run (no probe) never hunted the strap and it stayed amber. Wanting it must not turn GPS on, and the GPS probe
 * must not carry it any more.
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34])
class StrapHuntTest {
    private class FakeStrap : StrapScreenWant {
        var wants = 0
        var releases = 0
        override fun wants() { wants++ }
        override fun releases() { releases++ }
    }

    private val context: Context = RuntimeEnvironment.getApplication()

    @Test
    fun `a treadmill Ready wants the strap and starts no GPS`() {
        val strap = FakeStrap()
        val api = RecorderApiImpl(context, strap)
        api.startStrapHunt()
        assertEquals(1, strap.wants)
        assertFalse("wanting the strap must not turn GPS on", api.gpsProbeRunning)
    }

    @Test
    fun `the GPS probe no longer carries the strap`() {
        val strap = FakeStrap()
        val api = RecorderApiImpl(context, strap)
        api.startGpsProbe()
        assertTrue(api.gpsProbeRunning)
        assertEquals("the probe alone does not want the strap", 0, strap.wants)
        api.stopGpsProbe()
        assertFalse(api.gpsProbeRunning)
        assertEquals("stopping the probe does not let the strap go", 0, strap.releases)
    }

    @Test
    fun `stopping the probe for the belt keeps the strap wanted`() {
        val strap = FakeStrap()
        val api = RecorderApiImpl(context, strap)
        api.startStrapHunt()
        api.startGpsProbe()
        api.stopGpsProbe() // the runner picked the treadmill on Ready
        assertEquals(1, strap.wants)
        assertEquals(0, strap.releases)
        api.stopStrapHunt()
        assertEquals(1, strap.releases)
    }
}
