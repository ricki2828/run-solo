package app.runsolo.core.replay

import app.runsolo.core.gps.PointFilter
import app.runsolo.core.model.HrReading
import app.runsolo.core.model.LapSource
import app.runsolo.core.model.LocationFix
import app.runsolo.core.model.Phase
import app.runsolo.core.model.Preset
import app.runsolo.core.model.RunMode
import app.runsolo.core.record.RecorderCore
import app.runsolo.core.record.SampleTicker
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

class ReplaySourceTest {
    /** Runs scheduled actions in order, advancing a virtual wall clock by each delay. */
    private class InstantScheduler {
        var now = 1_000_000L
        val delays = ArrayList<Long>()
        var cancelled = 0
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
    fun `emits in time order at 1x, stamped on the trace timeline anchored at start`() {
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
        assertEquals(listOf(1_000_000L, 1_001_000L, 1_002_000L, 1_003_000L), fixes.map { it.t })
        assertEquals(listOf(1_001_000L, 1_002_500L), hrs.map { it.t })
        assertEquals(listOf(140, 142), hrs.map { it.bpm })
        assertEquals(1_003_000L, src.endT)
        assertFalse(src.running)
        val f = PointFilter()
        fixes.forEach { f.offer(it) }
        assertEquals(9.0, f.totalM, 0.1)
    }

    @Test
    fun `10x - wall delays shrink, stamps and now() stay on trace time`() {
        val s = InstantScheduler()
        val trace = TraceFixture.straightLine(listOf(5 to 3.0))
        val stamps = ArrayList<Long>()
        val nows = ArrayList<Long>()
        lateinit var src: ReplaySource
        src = ReplaySource(trace, emptyList(), 10.0, s.scheduler, { s.now }, { stamps.add(it.t); nows.add(src.now()) }, null)
        src.start()
        s.pump()
        assertEquals(listOf(0L, 100L, 100L, 100L, 100L, 100L), s.delays)
        assertEquals((0..5).map { 1_000_000L + it * 1000 }, stamps)
        assertEquals(stamps, nows, "now() equals the stamp of the item just emitted")
        val f = PointFilter()
        stamps.forEachIndexed { i, t -> f.offer(trace[i].copy(t = t)) }
        assertEquals(15.0, f.totalM, 0.1, "1 s apart on the trace clock, so the speed gate passes (first point anchors on the second)")
    }

    /** §12: a full 4x4 with auto-laps runs at the desk at 10×, on the replay clock end to end. */
    @Test
    fun `10x straight-line 4x4 through ticker and core - 8 auto laps on the boundaries, ground-truth distance`() {
        val preset = Preset.DEFAULT_4X4
        val segments = ArrayList<Pair<Int, Double>>()
        segments.add(30 to 2.5)
        repeat(preset.reps) { segments.add(preset.workSeconds to 4.2); segments.add(preset.recoverySeconds to 2.0) }
        segments.add(30 to 2.5)
        val trace = TraceFixture.straightLine(segments)
        val truthM = segments.sumOf { it.first * it.second }

        val s = InstantScheduler()
        val ticker = SampleTicker(wall = { 0 })
        lateinit var src: ReplaySource
        lateinit var core: RecorderCore
        val laps = ArrayList<RecorderCore.Output.Lap>()
        var samples = 0
        src = ReplaySource(
            trace, emptyList(), 10.0, s.scheduler, { s.now },
            { fix ->
                // What the service does per fix in replay mode: feed the ticker, run the 1 Hz tick on the replay clock.
                ticker.onFix(fix)
                val now = src.now()
                if (samples == 30) laps.addAll(core.lap(LapSource.notification, now).second.filterIsInstance<RecorderCore.Output.Lap>())
                laps.addAll(core.tick(now).filterIsInstance<RecorderCore.Output.Lap>())
                samples += ticker.tick(now).size
            },
            null,
        )
        core = RecorderCore(RunMode.fourByFour, preset)
        core.start(s.now)
        src.start()
        s.pump()

        assertEquals(trace.size, samples)
        assertEquals(9, laps.size)
        val auto = laps.filter { it.source == LapSource.auto }
        assertEquals(8, auto.size)
        val t0 = 1_000_000L + 30_000
        val expected = (1..8).map { i -> t0 + ((i + 1) / 2) * preset.workMs + (i / 2) * preset.recoveryMs }
        assertEquals(expected, auto.map { it.t })
        assertEquals(Phase.cooldown, core.phase)
        assertEquals(truthM, ticker.distanceM, truthM * 0.01)
        assertEquals(1, ticker.filter.rejectedCount, "only the unconfirmed first anchor point is counted as rejected")
        // Wall time: 25.5 min of trace in 2.55 min.
        assertEquals(trace.last().t / 10, s.now - 1_000_000L)
    }

    @Test
    fun `the last item is delivered with running already false, so the recorder can auto-stop`() {
        val s = InstantScheduler()
        val seen = ArrayList<Boolean>()
        lateinit var src: ReplaySource
        src = ReplaySource(TraceFixture.straightLine(listOf(2 to 1.0)), emptyList(), 1.0, s.scheduler, { s.now }, { seen.add(src.running) }, null)
        src.start()
        s.pump()
        assertEquals(listOf(true, true, false), seen)
        assertEquals(3, src.emitted)
        assertEquals(src.total, src.emitted)
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
        val json = """{"schema":1,"samples":[[0,-33.8,151.2,null,5,3.0,0,150],[1000,-33.8,151.20003,10.5,6,null,3.0,null],[2000,null,null,null,null,null,3.0,152]]}"""
        val t = TraceFixture.fromRunFileJson(json)
        assertEquals(2, t.fixes.size, "a no-fix sample is not a fix")
        assertNull(t.fixes[0].altM)
        assertEquals(10.5, t.fixes[1].altM)
        assertEquals(listOf(HrReading(0, 150), HrReading(2000, 152)), t.hr)
        assertTrue(t.fixes[1].speedMps == null)
    }
}
