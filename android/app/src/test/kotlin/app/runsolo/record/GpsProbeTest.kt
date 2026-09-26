package app.runsolo.record

import android.os.Handler
import android.os.Looper
import app.runsolo.core.model.LocationFix
import app.runsolo.platform.GpsProbeEvent
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config
import java.time.Duration

/** The pre-start GPS probe: one request while it runs, none after stop, no fix without permission. */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34])
class GpsProbeTest {
    private class FakeSource : LocationSource {
        var starts = 0
        var stops = 0
        var onFix: ((LocationFix) -> Unit)? = null
        override fun start(looper: Looper, onFix: (LocationFix) -> Unit) {
            starts++
            this.onFix = onFix
        }
        override fun stop() {
            stops++
            onFix = null
        }
    }

    private var now = 100_000L
    private val events = ArrayList<GpsProbeEvent>()
    private val src = FakeSource()
    private fun probe(permission: Boolean = true) =
        GpsProbe({ permission }, { src }, { events.add(it) }, clock = { now }, handler = Handler(Looper.getMainLooper()))

    private fun idle(ms: Long) {
        now += ms
        shadowOf(Looper.getMainLooper()).idleFor(Duration.ofMillis(ms))
    }

    @Test
    fun `start requests fixes once, reports readiness about 1 Hz, stop releases the request`() {
        val p = probe()
        p.start()
        p.start() // idempotent
        assertEquals(1, src.starts)
        idle(0)
        assertFalse("no fix yet", events.last().fix)
        src.onFix!!(LocationFix(now, -33.8, 151.2, null, 6.0, 0.0))
        idle(1_000)
        assertTrue(events.last().fix)
        assertEquals(6.0, events.last().accuracyM!!, 0.0)
        idle(6_000) // no fix for more than 5 s
        assertFalse("a stale fix is not ready", events.last().fix)
        assertNull(events.last().accuracyM)
        p.stop()
        p.stop()
        assertEquals(1, src.stops)
        assertFalse(p.running)
        val n = events.size
        idle(5_000)
        assertEquals("nothing after stop (no leak when the screen closes)", n, events.size)
    }

    @Test
    fun `without location permission it asks for nothing and reports no fix`() {
        val p = probe(permission = false)
        p.start()
        idle(2_000)
        assertEquals(0, src.starts)
        assertTrue(events.isNotEmpty() && events.none { it.fix })
        p.stop()
        assertEquals(0, src.stops)
    }
}
