package app.runsolo.core.replay

import app.runsolo.core.gps.PointFilter
import app.runsolo.core.model.HrReading
import app.runsolo.core.model.LocationFix
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

class ReplaySourceTest {
    /** Runs every scheduled action immediately, advancing a virtual clock by the delay. */
    private class InstantScheduler {
        var now = 1_000_000L
        val delays = ArrayList<Long>()
        var cancelled = 0
        var pumpDepth = 0
        val queue = ArrayDeque<Pair<Long, () -> Unit>>()

        val scheduler = Scheduler { delay, action ->
            delays.add(delay)
            queue.addLast(delay to action)
            Cancellable { cancelled++ }
        }

        fun pump() {
            while (queue.isNotEmpty()) {
                val (d, a) = queue.removeFirst()
                now += d
                a()
            }
        }
    }

    @Test
    fun `emits in time order at 1x with timestamps rewritten to the live clock`() {
        val s = InstantScheduler()
        val trace = TraceFixture.straightLine(listOf(3 to 3.0), startT = 5_000)
        val hr = listOf(HrReading(6_000, 140), HrReading(7_500, 142))
        val fixes = ArrayList<LocationFix>()
        val hrs = ArrayList<HrReading>()
        val src = ReplaySource(trace, hr, 1.0, s.scheduler, { s.now }, { fixes.add(it) }, { hrs.add(it) })
        src.start()
        s.pump()
        assertEquals(6, src.emitted)
        assertEquals(listOf(0L, 1000L, 0L, 1000L, 500L, 500L), s.delays)
        assertEquals(4, fixes.size)
        assertEquals(listOf(1_000_000L, 1_001_000L, 1_002_000L, 1_003_000L), fixes.map { it.t })
        assertEquals(listOf(1_001_000L, 1_002_500L), hrs.map { it.t })
        assertEquals(listOf(140, 142), hrs.map { it.bpm })
        assertFalse(src.running)
        // The recorder's filter sees 9 m of ground truth.
        val f = PointFilter()
        fixes.forEach { f.offer(it) }
        assertEquals(9.0, f.totalM, 0.1)
    }

    @Test
    fun `10x compresses the spacing`() {
        val s = InstantScheduler()
        val trace = TraceFixture.straightLine(listOf(5 to 3.0))
        val src = ReplaySource(trace, emptyList(), 10.0, s.scheduler, { s.now }, {}, null)
        src.start()
        s.pump()
        assertEquals(listOf(0L, 100L, 100L, 100L, 100L, 100L), s.delays)
    }

    @Test
    fun `stop cancels and nothing more is emitted`() {
        val s = InstantScheduler()
        var n = 0
        val src = ReplaySource(TraceFixture.straightLine(listOf(3 to 1.0)), emptyList(), 1.0, s.scheduler, { s.now }, { n++ }, null)
        src.start()
        src.stop()
        s.pump()
        assertEquals(0, n)
        assertEquals(1, s.cancelled)
        assertFalse(src.running)
    }

    @Test
    fun `csv fixture parses optional columns`() {
        val t = TraceFixture.fromCsv(
            """
            # t,lat,lon,alt,acc,speed,hr
            0,-33.8,151.2,12,5,3.1,150
            1000,-33.8,151.2001,,6,,
            """.trimIndent(),
        )
        assertEquals(2, t.fixes.size)
        assertEquals(12.0, t.fixes[0].altM)
        assertNull(t.fixes[1].altM)
        assertNull(t.fixes[1].speedMps)
        assertEquals(listOf(HrReading(0, 150)), t.hr)
    }

    @Test
    fun `run file json replays as a fixture`() {
        val json = """{"schema":1,"samples":[[0,-33.8,151.2,null,5,3.0,0,150],[1000,-33.8,151.20003,10.5,6,null,3.0,null]]}"""
        val t = TraceFixture.fromRunFileJson(json)
        assertEquals(2, t.fixes.size)
        assertNull(t.fixes[0].altM)
        assertEquals(10.5, t.fixes[1].altM)
        assertEquals(listOf(HrReading(0, 150)), t.hr)
        assertTrue(t.fixes[1].speedMps == null)
    }
}
