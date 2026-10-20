package app.runsolo.core.live

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

/** Planned-minutes cues for a plan easy or long run: thresholds, silence past planned, queueing, resume. */
class PlannedTimeCuesTest {
    private fun min(m: Int, s: Int = 0) = (m * 60 + s) * 1_000L

    /** Ticks each second over [fromMs]..[toMs] (inclusive); the lines said, by whole second. */
    private fun PlannedTimeCues.run(fromMs: Long, toMs: Long, busy: (Long) -> Long = { 0L }): List<Pair<Long, String>> {
        val out = ArrayList<Pair<Long, String>>()
        var e = fromMs
        while (e <= toMs) {
            tick(e, e, busy(e))?.let { out.add(e / 1_000 to it) }
            e += 1_000
        }
        return out
    }

    @Test
    fun `19 minutes planned has no halfway but does say 5 to go at 14 00`() {
        val c = PlannedTimeCues("easy", 19)
        assertEquals(listOf(min(14) / 1_000 to "5 minutes to go."), c.run(0, min(19)))
    }

    @Test
    fun `20 minutes planned says halfway at 10 00 and 5 to go at 15 00`() {
        val c = PlannedTimeCues("long", 20)
        assertEquals(
            listOf(min(10) / 1_000 to "Halfway.", min(15) / 1_000 to "5 minutes to go."),
            c.run(0, min(21)),
        )
    }

    @Test
    fun `14 minutes planned has no 5 to go and no halfway`() {
        val c = PlannedTimeCues("easy", 14)
        assertFalse(c.active)
        assertEquals(emptyList(), c.run(0, min(15)))
    }

    @Test
    fun `15 minutes planned says 5 to go at 10 00 only`() {
        val c = PlannedTimeCues("easy", 15)
        assertEquals(listOf(min(10) / 1_000 to "5 minutes to go."), c.run(0, min(16)))
    }

    @Test
    fun `45 minutes planned says halfway at 22 30`() {
        val c = PlannedTimeCues("long", 45)
        assertEquals(listOf(1_350L to "Halfway.", 2_400L to "5 minutes to go."), c.run(0, min(46)))
    }

    @Test
    fun `past planned time it is silent even for a cue that never got its turn`() {
        val c = PlannedTimeCues("easy", 20)
        assertNull(c.tick(min(20), min(20), 0))
        assertNull(c.tick(min(25), min(25), 0))
        // 5 to go was never said (a long km line in the way the whole time): still not said at 21:00.
        val d = PlannedTimeCues("easy", 20)
        assertEquals("Halfway.", d.tick(min(10), min(10), 0))
        assertNull(d.tick(min(20, 1), min(20, 1), 0))
    }

    @Test
    fun `other kinds and missing minutes never speak`() {
        for (c in listOf(
            PlannedTimeCues(null, 40),
            PlannedTimeCues("interval", 40),
            PlannedTimeCues("goal", 40),
            PlannedTimeCues("easy", null),
            PlannedTimeCues("easy", 0),
        )) {
            assertFalse(c.active)
            assertEquals(emptyList(), c.run(0, min(41)))
        }
    }

    @Test
    fun `each line is said once`() {
        val c = PlannedTimeCues("easy", 30)
        assertEquals("Halfway.", c.tick(min(15), min(15), 0))
        assertNull(c.tick(min(15, 1), min(15, 1), 0))
        assertNull(c.tick(min(15, 2), min(15, 2), 0))
    }

    @Test
    fun `a cue on a km line queues behind it and is said when the speech ends`() {
        val c = PlannedTimeCues("easy", 30)
        val busyUntil = min(15) + 4_000
        val said = c.run(min(15), min(16)) { busyUntil }
        assertEquals(emptyList(), said.filter { it.first * 1_000 < busyUntil })
        // Busy until 15:04 the whole window: said on the first tick at or after it.
        assertEquals(listOf((min(15) + 4_000) / 1_000 to "Halfway."), said)
    }

    @Test
    fun `a cue more than 20 s late is dropped and not said at the wrong moment`() {
        val c = PlannedTimeCues("easy", 30)
        assertEquals(emptyList(), c.run(min(15), min(15, 40)) { min(15, 30) })
        assertNull(c.tick(min(15, 45), min(15, 45), 0), "halfway is gone for good")
        assertEquals("5 minutes to go.", c.tick(min(25), min(25), 0))
    }

    @Test
    fun `a resume does not re-fire what already passed`() {
        val c = PlannedTimeCues("easy", 30)
        assertEquals("Halfway.", c.tick(min(15), min(15), 0))
        // Killed at 16:00 and restored at 18:00 (the dark gap counts): a fresh instance, rebuilt from the clock.
        val restored = PlannedTimeCues("easy", 30)
        restored.restoredAt(min(18))
        assertEquals(emptyList(), restored.run(min(18), min(24, 59)))
        assertEquals(listOf(min(25) / 1_000 to "5 minutes to go."), restored.run(min(25), min(29)))
    }

    @Test
    fun `a resume before halfway still says it`() {
        val restored = PlannedTimeCues("long", 40)
        restored.restoredAt(min(5))
        assertEquals(listOf(min(20) / 1_000 to "Halfway."), restored.run(min(5), min(21)))
    }

    @Test
    fun `lines keep the copy rules`() {
        for (text in listOf(app.runsolo.core.record.CueWords.PLANNED_HALFWAY, app.runsolo.core.record.CueWords.plannedToGo(5))) {
            assertFalse(text.contains('—'), text)
            assertTrue(CueComposer.words(text) <= CueComposer.MAX_WORDS, text)
        }
        assertEquals("1 minute to go.", app.runsolo.core.record.CueWords.plannedToGo(1))
    }
}
