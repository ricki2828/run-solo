package app.runsolo.core.run

import app.runsolo.core.journal.JournalCodec
import app.runsolo.core.journal.JournalLine
import app.runsolo.core.journal.JournalReplay
import app.runsolo.core.json.list
import app.runsolo.core.model.RunMode
import app.runsolo.core.model.Units
import app.runsolo.core.replay.TraceFixture
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

/** Auto-pause in the run file: `pauses[]` carries a kind, distance keeps counting, a stop ends where the pause began. */
class AutoPauseRunFileTest {
    private val t0 = 50_000L
    private val w0 = 1_700_000_000_000L
    private val header = JournalLine.Header(t0, w0, "id1", "dev", "app", "UTC", RunMode.free, null, Units.km)

    /** 50 s at 3 m/s with [events] (run-time ms to line) inserted before the sample at that second. */
    private fun journal(vararg events: Pair<Long, (Long, Long) -> JournalLine>): ByteArray {
        val fixes = TraceFixture.straightLine(listOf(50 to 3.0), startT = t0)
        val sb = StringBuilder(JournalCodec.encode(header)).append('\n')
        for (f in fixes) {
            val runT = f.t - t0
            for ((at, make) in events) if (at == runT) sb.append(JournalCodec.encode(make(f.t, w0 + runT))).append('\n')
            sb.append(JournalCodec.encode(JournalLine.Sample(f.t, w0 + runT, f.lat, f.lon, f.altM, f.accuracyM, f.speedMps, null))).append('\n')
        }
        return sb.toString().toByteArray()
    }

    private val apause: (Long, Long) -> JournalLine = { t, w -> JournalLine.AutoPause(t, w) }
    private val aresume: (Long, Long) -> JournalLine = { t, w -> JournalLine.AutoResume(t, w) }
    private val pause: (Long, Long) -> JournalLine = { t, w -> JournalLine.Pause(t, w) }
    private val resume: (Long, Long) -> JournalLine = { t, w -> JournalLine.Resume(t, w) }

    private fun file(vararg events: Pair<Long, (Long, Long) -> JournalLine>) =
        RunFile.fromReplay(JournalReplay.read(journal(*events)), w0 + 50_000)

    @Test
    fun `an auto-pause is a span with the auto kind, and the distance does not re-anchor`() {
        val plain = file()
        val f = file(40_000L to apause, 45_000L to aresume)
        assertEquals(1, f.pauses.size)
        assertEquals(listOf(40_000L, 45_000L), f.pauses[0].take(2))
        assertTrue(RunFile.isAutoPause(f.pauses[0]))
        // Frozen like a manual pause, but with no re-anchor: the first fix after it steps from where the
        // runner stopped, so ground really covered (this trace keeps moving) is not lost, as a manual pause loses it.
        assertEquals(plain.distanceM, f.distanceM, 1.0)
        assertTrue(f.distanceM > file(40_000L to pause, 45_000L to resume).distanceM + 10.0, "a manual pause drops the paused steps")
        assertEquals(51, f.samples.size)
        assertEquals(50_000, f.elapsedMs, "elapsed is unchanged")
    }

    @Test
    fun `the JSON writes auto spans with a third element and manual spans with two`() {
        val f = file(10_000L to pause, 15_000L to resume, 40_000L to apause, 45_000L to aresume)
        val json = RunFile.readJson(f.toGzipBytes())
        val pauses = json.list("pauses")!!.map { (it as List<*>).toList() }
        assertEquals(listOf(listOf(10_000L, 15_000L), listOf(40_000L, 45_000L, "auto")), pauses)
    }

    @Test
    fun `a manual pause is unchanged, frozen and re-anchored`() {
        val f = file(40_000L to pause, 45_000L to resume)
        assertEquals(listOf(40_000L, 45_000L), f.pauses.single().asList())
        assertFalse(RunFile.isAutoPause(f.pauses.single()))
        assertTrue(f.distanceM < file().distanceM - 10, "5 paused seconds and the re-anchor are not counted")
    }

    @Test
    fun `PAUSE on top of an auto-pause splits it, auto then manual`() {
        val f = file(30_000L to apause, 35_000L to pause, 45_000L to resume)
        assertEquals(2, f.pauses.size)
        assertEquals(listOf(30_000L, 35_000L), f.pauses[0].take(2))
        assertTrue(RunFile.isAutoPause(f.pauses[0]))
        assertEquals(listOf(35_000L, 45_000L), f.pauses[1].asList())
        assertFalse(RunFile.isAutoPause(f.pauses[1]))
    }

    @Test
    fun `a run stopped in an auto-pause ends where it began, nothing trailing`() {
        val f = file(40_000L to apause)
        assertEquals(0, f.pauses.size)
        assertEquals(40_000, f.elapsedMs)
        assertEquals(40_000L, f.laps.last().t1)
        assertTrue(f.samples.all { it.t <= 40_000 })
        assertEquals(f.distanceM, f.laps.last().d1, 0.0001, "the last lap ends at the last kept sample's distance")
    }

    @Test
    fun `a run stopped after PAUSE on an auto-pause also ends at the auto-pause`() {
        val f = file(30_000L to apause, 35_000L to pause)
        assertEquals(0, f.pauses.size)
        assertEquals(30_000, f.elapsedMs)
    }

    @Test
    fun `a stray resume with nothing paused is ignored`() {
        val f = file(20_000L to aresume, 25_000L to resume)
        assertEquals(0, f.pauses.size)
        assertNull(f.pauses.firstOrNull())
    }

    @Test
    fun `journal lines round-trip and an auto-pause ends the replay paused`() {
        for (line in listOf(JournalLine.AutoPause(5, 6), JournalLine.AutoResume(7, 8))) {
            assertEquals(line, JournalCodec.decode(JournalCodec.encode(line)))
        }
        val r = JournalReplay.read(journal(40_000L to apause))
        assertTrue(r.isPaused)
        assertFalse(JournalReplay.read(journal(40_000L to apause, 45_000L to aresume)).isPaused)
    }
}
