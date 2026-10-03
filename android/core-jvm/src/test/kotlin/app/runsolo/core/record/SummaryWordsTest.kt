package app.runsolo.core.record

import app.runsolo.core.live.CueComposer
import app.runsolo.core.model.RunMode
import app.runsolo.core.model.SessionSpec
import app.runsolo.core.model.Units
import app.runsolo.core.replay.ReplayScenarios
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull
import kotlin.test.assertTrue

class SummaryWordsTest {
    private val fourByFour = SessionSpec.norwegian4x4()

    @Test
    fun `start says the trail with its route, distance and climb`() {
        assertEquals(
            "Trail run. Following Kastro loop, 6.2 kilometres, 230 metres of climb.",
            SummaryWords.start(RunMode.trail, null, Units.km, "Kastro loop", 6_210.0, 231.0),
        )
    }

    @Test
    fun `start leaves climb out when the route has no elevation`() {
        assertEquals(
            "Trail run. Following Kastro loop, 6.2 kilometres.",
            SummaryWords.start(RunMode.trail, null, Units.km, "Kastro loop", 6_210.0, null),
        )
    }

    @Test
    fun `start has a trail run with no route and a trail with a long name that still fits`() {
        assertEquals("Trail run.", SummaryWords.start(RunMode.trail, null, Units.km))
        val long = SummaryWords.start(RunMode.trail, null, Units.km, "Mount Wellington summit via the old pipe track and back", 6_210.0, 231.0)!!
        assertTrue(CueComposer.words(long) <= CueComposer.MAX_WORDS, long)
        assertTrue(long.startsWith("Trail run. Following Mount Wellington"), long)
    }

    @Test
    fun `start in miles says miles and feet`() {
        assertEquals(
            "Trail run. Following Kastro loop, 3.9 miles, 760 feet of climb.",
            SummaryWords.start(RunMode.trail, null, Units.mi, "Kastro loop", 6_210.0, 231.0),
        )
        assertEquals("Trail run. Following Park lap, 1 mile.", SummaryWords.start(RunMode.trail, null, Units.mi, "Park lap", 1_609.0, null))
    }

    @Test
    fun `start says the 4x4 and free run, with the goal when there is one`() {
        assertEquals("Norwegian 4x4. Warm up as long as you like.", SummaryWords.start(RunMode.intervals, fourByFour, Units.km))
        assertEquals("Free run.", SummaryWords.start(RunMode.free, null, Units.km))
        val tenK = SessionSpec.goalDistance(10_000, "10K").copy(spokenName = "10 K")
        assertEquals("Free run. Goal: 10 kilometres.", SummaryWords.start(RunMode.free, tenK, Units.km))
        assertEquals("Free run. Goal: 6.2 miles.", SummaryWords.start(RunMode.free, SessionSpec.goalDistance(10_000, "10K"), Units.mi))
        assertEquals("Free run. Goal: 30 minutes.", SummaryWords.start(RunMode.free, SessionSpec.goalTime(1_800, "30 min"), Units.km))
        assertEquals("Free run. Goal: 1 hour 15 minutes.", SummaryWords.start(RunMode.free, SessionSpec.goalTime(4_500, "1 h 15"), Units.km))
    }

    @Test
    fun `end says distance, time, pace and climb`() {
        assertEquals(
            "5 kilometres 20, 41 minutes, 7 minutes 53 per kilometre, 230 metres of climb.",
            SummaryWords.end(5_200.0, 2_460_000, Units.km, climbM = 230.0),
        )
    }

    @Test
    fun `end number phrasing`() {
        assertEquals("5 kilometres, 25 minutes, 5 minutes per kilometre.", SummaryWords.end(5_000.0, 1_500_000, Units.km))
        assertEquals("5 kilometres oh 5, 25 minutes 12, 4 minutes 59 per kilometre.", SummaryWords.end(5_050.0, 1_512_000, Units.km))
        assertEquals("800 metres, 4 minutes, 5 minutes per kilometre.", SummaryWords.end(800.0, 240_000, Units.km))
        assertEquals("1 kilometre 50, 45 seconds, 30 seconds per kilometre.", SummaryWords.end(1_500.0, 45_000, Units.km))
        assertEquals("21 kilometres 10, 1 hour 50 minutes, 5 minutes 13 per kilometre.", SummaryWords.end(21_100.0, 6_600_000, Units.km))
    }

    @Test
    fun `end in miles`() {
        assertEquals(
            "3 miles 11, 30 minutes, 9 minutes 39 per mile, 755 feet of climb.",
            SummaryWords.end(5_000.0, 1_800_000, Units.mi, climbM = 230.0),
        )
    }

    @Test
    fun `end leaves a small climb out and keeps 20 metres`() {
        assertEquals("5 kilometres, 25 minutes, 5 minutes per kilometre.", SummaryWords.end(5_000.0, 1_500_000, Units.km, climbM = 19.0))
        assertEquals("5 kilometres, 25 minutes, 5 minutes per kilometre, 20 metres of climb.", SummaryWords.end(5_000.0, 1_500_000, Units.km, climbM = 20.0))
    }

    @Test
    fun `end speaks the verdict after the stats, and the stats alone when none is computed yet`() {
        val stats = "5 kilometres, 25 minutes, 5 minutes per kilometre."
        assertEquals("$stats No real change.", SummaryWords.end(5_000.0, 1_500_000, Units.km, verdict = "No real change."))
        assertEquals(stats, SummaryWords.end(5_000.0, 1_500_000, Units.km, verdict = null))
        assertEquals(stats, SummaryWords.end(5_000.0, 1_500_000, Units.km, verdict = "  "))
    }

    @Test
    fun `end with no distance says only the verdict`() {
        assertEquals("No verdict.", SummaryWords.end(0.0, 1_500_000, Units.km, verdict = "No verdict."))
        assertNull(SummaryWords.end(0.0, 1_500_000, Units.km))
    }

    @Test
    fun `start of an event is its own name`() {
        assertEquals("${ReplayScenarios.PARKRUN.spoken}.", SummaryWords.start(RunMode.intervals, ReplayScenarios.PARKRUN, Units.km))
    }
}
