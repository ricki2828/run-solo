package app.runsolo.core.live

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

class TalkBudgetTest {
    private fun line(slot: CueSlot, key: String, text: String, value: Double? = null, step: Double? = null) = TalkLine(slot, key, text, value, step)

    private fun coach() = TalkBudget(VoiceLevel.coach)

    private val sevenWords = "one two three four five six seven."

    @Test
    fun `P0 is never dropped even back to back and over budget`() {
        val b = coach()
        for (i in 0 until 6) assertNotNull(b.offer(line(CueSlot.structure, "s$i", sevenWords), i * 100L, 0L, hardEffort = true))
        assertNotNull(b.offer(line(CueSlot.turnaround, "t", "Turn here."), 700L, 0L))
        assertNotNull(b.offer(line(CueSlot.offRoute, "o", "Off route."), 800L, 0L))
    }

    @Test
    fun `a km line inside the gap after another line is dropped and after it is said`() {
        val b = coach()
        assertNotNull(b.offer(line(CueSlot.turnaround, "t", "Turn here."), 0L, 0L))
        assertNull(b.offer(line(CueSlot.km, "km:1", "1 k."), 10_000L, 0L))
        assertNotNull(b.offer(line(CueSlot.km, "km:2", "2 k."), 26_000L, 0L))
    }

    @Test
    fun `speech still queued ahead counts for the gap`() {
        val b = coach()
        assertNull(b.offer(line(CueSlot.km, "km:1", "1 k."), 10_000L, 20_000L))
        assertNotNull(b.offer(line(CueSlot.km, "km:1", "1 k."), 46_000L, 20_000L))
    }

    @Test
    fun `P2 to P4 share 30 words per 3 minutes and the window rolls`() {
        val b = coach()
        for (i in 0 until 4) assertNotNull(b.offer(line(CueSlot.ghostGap, "g$i", sevenWords), i * 30_000L, 0L))
        assertNull(b.offer(line(CueSlot.ghostGap, "g4", sevenWords), 120_000L, 0L))
        assertNotNull(b.offer(line(CueSlot.ghostGap, "g5", sevenWords), 190_000L, 0L))
    }

    @Test
    fun `P1 game beats are not held to the words budget`() {
        val b = coach()
        for (i in 0 until 5) assertNotNull(b.offer(line(CueSlot.climbDone, "c$i", sevenWords), i * 30_000L, 0L))
    }

    @Test
    fun `a key already said waits for its value to move`() {
        val b = coach()
        assertNotNull(b.offer(line(CueSlot.zoneDrift, "z", "Zone 3.", 3.0, 1.0), 0L, 0L))
        assertNull(b.offer(line(CueSlot.zoneDrift, "z", "Zone 3.", 3.0, 1.0), 60_000L, 0L))
        assertNotNull(b.offer(line(CueSlot.zoneDrift, "z", "Zone 4.", 4.0, 1.0), 120_000L, 0L))
    }

    @Test
    fun `a km line that finds a held event takes it along in one utterance`() {
        val b = coach()
        assertNotNull(b.offer(line(CueSlot.turnaround, "t", "Turn here."), 0L, 0L))
        assertNull(b.offer(line(CueSlot.climbAhead, "c", "Climb ahead. 70 metres up."), 20_000L, 0L))
        val said = b.offer(line(CueSlot.km, "km:4", "4 k. 31 minutes 12. pace 7:48."), 26_000L, 0L)
        assertEquals("4 k. Climb ahead. 70 metres up.", said?.text)
        assertTrue(said!!.words <= TalkBudget.MERGE_MAX_WORDS)
        assertNull(b.poll(27_000L, 0L), "the event is not said a second time")
    }

    @Test
    fun `a merge too long for 14 words says the km line whole`() {
        val km = line(CueSlot.km, "km:4", "4 k. 31 minutes 12.")
        val event = line(CueSlot.climbAhead, "c", "Climb ahead. one two three four five six seven eight nine ten eleven twelve.")
        assertEquals(km, TalkBudget.merge(km, event))
    }

    @Test
    fun `a held game beat is said when the gap opens and dropped after 10 seconds`() {
        val b = coach()
        assertNotNull(b.offer(line(CueSlot.turnaround, "t", "Turn here."), 0L, 0L))
        assertNull(b.offer(line(CueSlot.climbAhead, "c", "Climb ahead."), 18_000L, 0L))
        assertNull(b.poll(20_000L, 0L))
        assertEquals("Climb ahead.", b.poll(26_000L, 0L)?.text)
        assertNull(b.poll(27_000L, 0L))
        // held at 100 s, still waiting behind a long P0 line, then stale
        assertNotNull(b.offer(line(CueSlot.structure, "s", sevenWords + " " + sevenWords), 100_000L, 0L))
        assertNull(b.offer(line(CueSlot.finalPush, "f", "One k left."), 101_000L, 0L))
        assertNull(b.poll(112_000L, 0L))
        assertNull(b.poll(200_000L, 0L))
    }

    @Test
    fun `hard effort silences the km and half km but not a game beat`() {
        val b = coach()
        assertNull(b.offer(line(CueSlot.km, "km:1", "1 k."), 0L, 0L, hardEffort = true))
        assertNull(b.offer(line(CueSlot.halfKm, "halfKm:zone", "Zone 4."), 1_000L, 0L, hardEffort = true))
        assertNotNull(b.offer(line(CueSlot.climbDone, "c", "Climb done."), 2_000L, 0L, hardEffort = true))
    }

    @Test
    fun `minimal says the km word and structure only`() {
        val b = TalkBudget(VoiceLevel.minimal)
        assertNotNull(b.offer(line(CueSlot.km, "km:1", "1 k."), 0L, 0L))
        assertNull(b.offer(line(CueSlot.halfKm, "h", "Zone 3."), 100_000L, 0L))
        assertNull(b.offer(line(CueSlot.zoneDrift, "z", "Ease off."), 100_000L, 0L))
        assertNull(b.offer(line(CueSlot.climbAhead, "c", "Climb ahead."), 100_000L, 0L))
        assertNotNull(b.offer(line(CueSlot.turnaround, "t", "Turn here."), 100_000L, 0L))
    }

    @Test
    fun `everything only de-dupes with no gap and no words budget`() {
        val b = TalkBudget(VoiceLevel.everything)
        for (i in 0 until 6) assertNotNull(b.offer(line(CueSlot.halfKm, "h$i", sevenWords), i * 1_000L, 0L, hardEffort = true))
        assertNull(b.offer(line(CueSlot.halfKm, "h0", sevenWords), 7_000L, 0L))
    }

    @Test
    fun `recorded lines count for the gap and the words but are never gated`() {
        val b = coach()
        b.record(line(CueSlot.paceStatus, "n", sevenWords), 0L, 0L)
        assertNull(b.offer(line(CueSlot.km, "km:1", "1 k."), 10_000L, 0L))
        b.record(line(CueSlot.paceStatus, "n2", sevenWords), 10_000L, 0L)
    }

    @Test
    fun `the two Ricki examples fit the new budgets`() {
        val plan = CheckInPlan(CheckInMetric.DEFAULT, listOf(120.0, 140.0, 160.0, 175.0), VoiceLevel.coach)
        val trail = CoachWords.km(plan, 4, 1_872_000, 468_000, CheckInSnapshot(ghostAheadSec = 12.0, climbM = 85.0), true, 60.0, null)
        assertEquals("4 k. 12 seconds up on your best.", trail.base)
        val free = CoachWords.km(plan, 4, 1_872_000, 468_000, null, false, null, null)
        assertEquals("4 k. 31 minutes 12. pace 7:48.", free.base)
        assertTrue(CueComposer.words(trail.base) <= CoachWords.MAX_WORDS && CueComposer.words(free.base) <= CoachWords.MAX_WORDS)
        assertNull(trail.tail)
    }

    @Test
    fun `a noisy ghost around level says nothing and a real flip is said once`() {
        val g = AheadBehindGate()
        assertNull(g.update(0L, 0.0, 10.0))
        assertNull(g.update(30_000L, 90.0, 10.0), "the first side is the baseline")
        var t = 31_000L
        for (i in 0 until 40) {
            assertNull(g.update(t, t / 1000.0 * 3, if (i % 2 == 0) 4.0 else -4.0))
            t += 1_000L
        }
        var flips = 0
        for (i in 0 until 60) {
            if (g.update(t, t / 1000.0 * 3, -8.0) == -1) flips++
            t += 1_000L
        }
        assertEquals(1, flips)
    }

    @Test
    fun `a flip back inside 500 m is not said`() {
        val g = AheadBehindGate()
        g.update(0L, 0.0, 10.0)
        g.update(30_000L, 90.0, 10.0)
        g.update(31_000L, 93.0, -8.0)
        assertEquals(-1, g.update(61_000L, 183.0, -8.0))
        g.update(62_000L, 186.0, 8.0)
        assertNull(g.update(92_000L, 276.0, 8.0))
    }
}
