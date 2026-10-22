package app.runsolo.core.live

import app.runsolo.core.journal.JournalLine
import app.runsolo.core.model.CueKind
import app.runsolo.core.model.LiveBoard
import app.runsolo.core.model.LiveBoardKind
import app.runsolo.core.model.LiveContext
import app.runsolo.core.model.LiveEntry
import app.runsolo.core.model.Phase
import app.runsolo.core.model.RunMode
import app.runsolo.core.model.SessionSpec
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

/** The comparison maths and the cap of "chase your best" (the pre-run choice). No clocks: run time is data. */
class ChaseCoachTest {
    private fun fiveK(vararg entries: Pair<String, List<Long>>) = LiveBoard(
        key = "be:5000", label = "5K", kind = LiveBoardKind.distance, targetM = 5_000.0,
        entries = entries.map { (id, s) -> LiveEntry(id, 0, fromStartSplitsMs = s, finalMetric = s.last().toDouble()) },
    )

    /** An even-paced 5K: km k at k * [perKmMs]. */
    private fun even(perKmMs: Long) = List(5) { (it + 1) * perKmMs }

    private val best = "best" to even(290_000) // 24:10
    private val slower = "slower" to even(310_000)

    // ---- the maths ----

    @Test
    fun `base is the single fastest 5K read at the same km`() {
        val g = assertNotNull(ChaseCompare.vsBest(fiveK(slower, best), 3, 880_000))
        assertEquals("best", g.baseRunId)
        assertEquals(880_000L - 870_000L, g.deltaMs)
        assertEquals(-5_000L, ChaseCompare.vsBest(fiveK(best), 2, 575_000)!!.deltaMs)
    }

    @Test
    fun `a fast starter is not blended in - the base is the run with the fastest whole 5K`() {
        // "fade" is quickest at km 1 to 3 but ends slower than "steady": steady is the base at every km.
        val fade = "fade" to listOf(270_000L, 540_000L, 810_000L, 1_200_000L, 1_600_000L)
        val steady = "steady" to even(300_000)
        val board = fiveK(fade, steady)
        for (km in 1..5) assertEquals("steady", ChaseCompare.vsBest(board, km, 1_000L * km)!!.baseRunId)
        assertEquals(0L, ChaseCompare.vsBest(board, 3, 900_000)!!.deltaMs)
    }

    @Test
    fun `entries that cannot be a base are skipped - short splits and bad splits`() {
        val short = "short" to listOf(200_000L, 400_000L, 600_000L) // 3 splits for a 5K board
        val zero = "zero" to listOf(0L, 100_000L, 200_000L, 300_000L, 400_000L)
        val flat = "flat" to listOf(100_000L, 200_000L, 200_000L, 300_000L, 400_000L) // not strictly increasing
        val g = assertNotNull(ChaseCompare.vsBest(fiveK(short, zero, flat, slower), 1, 300_000))
        assertEquals("slower", g.baseRunId)
        assertNull(ChaseCompare.vsBest(fiveK(short, zero, flat), 1, 300_000), "no usable base, no comparison")
    }

    @Test
    fun `no base cases - empty board - past the board - no time yet - not a distance board`() {
        assertNull(ChaseCompare.vsBest(fiveK(), 1, 300_000))
        assertNull(ChaseCompare.vsBest(fiveK(best), 6, 1_700_000), "km 6 is past a 5K board")
        assertNull(ChaseCompare.vsBest(fiveK(best), 0, 100_000))
        assertNull(ChaseCompare.vsBest(fiveK(best), 2, 0))
        assertNull(ChaseCompare.vsBest(fiveK(best).copy(targetM = null), 2, 580_000))
        assertNull(ChaseCompare.vsBest(fiveK().copy(kind = LiveBoardKind.cooper), 2, 580_000))
    }

    @Test
    fun `a half marathon board reads 21 km from its 21097 m distance`() {
        val half = LiveBoard(
            key = "be:21097", label = "Half", kind = LiveBoardKind.distance, targetM = 21_097.5,
            entries = listOf(LiveEntry("h", 0, fromStartSplitsMs = List(21) { (it + 1) * 330_000L }, finalMetric = 6_930_000.0)),
        )
        assertEquals(21, ChaseCompare.boardKm(half))
        assertEquals(10_000L, ChaseCompare.vsBest(half, 19, 19 * 330_000L + 10_000)!!.deltaMs)
    }

    // ---- the policy ----

    private fun gap(deltaMs: Long) = ChaseCompare.Gap(deltaMs, "r")

    private fun chase(furthest: Double? = null, goal: Double? = null, fired: List<JournalLine.CueFired> = emptyList()) =
        ChaseCoach(CoachChoice.chase, furthest, goal, fired)

    @Test
    fun `km 1 is never a gap line - a fast start is not news`() {
        assertNull(chase().atKm(1, gap(-20_000), "5K"))
    }

    @Test
    fun `ahead and behind wording with the board label and the spoken gap`() {
        assertEquals("10 seconds up on your best 5K.", chase().atKm(2, gap(-10_000), "5K")!!.text)
        assertEquals("12 seconds off your best 5K.", chase().atKm(2, gap(12_000), "5K")!!.text)
        assertEquals("1 minute 5 off your best 10K.", chase().atKm(7, gap(65_000), "10K")!!.text)
        assertEquals(ChaseKind.ahead, chase().atKm(2, gap(-10_000), "5K")!!.kind)
        assertEquals(ChaseKind.behind, chase().atKm(2, gap(10_000), "5K")!!.kind)
    }

    @Test
    fun `under 3 seconds is level and says nothing`() {
        assertNull(chase().atKm(2, gap(2_400), "5K"))
        assertNull(chase().atKm(2, gap(-2_400), "5K"))
        assertNotNull(chase().atKm(2, gap(3_000), "5K"))
    }

    @Test
    fun `no gap or no label - no line`() {
        assertNull(chase().atKm(3, null, "5K"))
        assertNull(chase().atKm(3, gap(-10_000), null))
    }

    @Test
    fun `a gap line every second km only - a km is offered once`() {
        val c = chase()
        val k2 = assertNotNull(c.atKm(2, gap(-10_000), "5K"))
        c.said(k2)
        assertNull(c.atKm(3, gap(-11_000), "5K"), "one km after a line")
        assertNull(c.atKm(3, gap(-11_000), "5K"), "same km again")
        assertNotNull(c.atKm(4, gap(-12_000), "5K"))
    }

    @Test
    fun `a line the budget dropped is not counted so the next km may speak`() {
        val c = chase()
        assertNotNull(c.atKm(2, gap(-10_000), "5K")) // offered, never said()
        assertNotNull(c.atKm(3, gap(-10_000), "5K"))
    }

    @Test
    fun `falling behind speaks out of turn as slipping and back ahead too`() {
        val c = chase()
        c.said(c.atKm(2, gap(-8_000), "5K")!!)
        val slip = assertNotNull(c.atKm(3, gap(6_000), "5K"))
        assertEquals(ChaseKind.slipping, slip.kind)
        assertEquals("Slipping, 6 seconds off your best 5K.", slip.text)
        c.said(slip)
        val back = assertNotNull(c.atKm(4, gap(-4_000), "5K"))
        assertEquals(ChaseKind.ahead, back.kind)
    }

    @Test
    fun `a level km in between does not hide a flip - the side is the last one seen`() {
        val c = chase()
        c.said(c.atKm(2, gap(-8_000), "5K")!!)
        assertNull(c.atKm(3, gap(1_000), "5K"), "level, not news")
        assertEquals(ChaseKind.slipping, c.atKm(4, gap(7_000), "5K")!!.kind)
    }

    @Test
    fun `at most 5 gap lines a run`() {
        val c = chase()
        var said = 0
        for (km in 2..30) {
            c.atKm(km, gap(if (km % 4 == 0) -9_000 else 9_000), "5K")?.let {
                c.said(it)
                said++
            }
        }
        assertEquals(ChaseCoach.MAX_GAP_LINES, said)
    }

    @Test
    fun `a restore keeps the cap and the spacing from the journaled chase lines`() {
        val fired = listOf(
            JournalLine.CueFired(0, 0, JournalLine.FiredKind.chase, "ahead", 2, 1),
            JournalLine.CueFired(0, 0, JournalLine.FiredKind.chase, "behind", 4, 1),
            JournalLine.CueFired(0, 0, JournalLine.FiredKind.compare, "be:5000", 5, 1),
        )
        val c = chase(fired = fired)
        assertNull(c.atKm(5, gap(9_000), "10K"), "one km after the km 4 line")
        assertNotNull(c.atKm(6, gap(9_000), "10K"))
    }

    // ---- furthest this month ----

    @Test
    fun `furthest run this month fires once at the first km past it`() {
        val c = chase(furthest = 8_400.0)
        assertNull(c.atKm(8, null, null), "8 km is not past 8.4")
        val f = assertNotNull(c.atKm(9, null, null))
        assertEquals(ChaseKind.furthest, f.kind)
        assertEquals("Furthest run this month.", f.text)
        c.said(f)
        assertNull(c.atKm(10, null, null))
    }

    @Test
    fun `a furthest line the budget dropped is offered again at the next km - and still true`() {
        val c = chase(furthest = 4_000.0)
        assertNotNull(c.atKm(5, null, null))
        assertEquals(ChaseKind.furthest, c.atKm(6, null, null)!!.kind)
    }

    @Test
    fun `no month base - no furthest line`() {
        assertNull(chase(furthest = null).atKm(9, null, null))
        assertNull(ChaseCoach.of(CoachChoice.chase, true, null, Double.NaN)!!.atKm(9, null, null))
    }

    @Test
    fun `furthest wins the km over a gap line`() {
        val c = chase(furthest = 4_500.0)
        assertEquals(ChaseKind.furthest, c.atKm(5, gap(-9_000), "5K")!!.kind)
    }

    // ---- last 2 km of a goal ----

    @Test
    fun `5K goal - 2 k to go at km 3 with the gap`() {
        val c = chase(goal = 5_000.0)
        assertNotEquals(ChaseKind.last2k, c.atKm(2, gap(-9_000), "5K")!!.kind)
        val l = assertNotNull(c.atKm(3, gap(-9_000), "5K"))
        assertEquals(ChaseKind.last2k, l.kind)
        assertEquals("2 k to go, 9 seconds up on your best 5K.", l.text)
        assertEquals("2 k to go.", l.shortText, "what is said if the gap would not fit the 16-word cue")
        c.said(l)
        assertNotEquals(ChaseKind.last2k, c.atKm(4, gap(-9_000), "5K")?.kind)
    }

    private fun assertNotEquals(a: Any?, b: Any?) = assertFalse(a == b, "expected different values, both $a")

    @Test
    fun `last 2 km without a base is just the distance to go`() {
        assertEquals("2 k to go.", chase(goal = 10_000.0).atKm(8, null, null)!!.text)
    }

    @Test
    fun `odd goal distances say the real distance to go`() {
        assertEquals("2.5 k to go.", chase(goal = 7_500.0).atKm(5, null, null)!!.text)
        assertEquals("2.1 k to go.", chase(goal = 21_098.0).atKm(19, null, null)!!.text)
        assertNull(chase(goal = 21_098.0).atKm(18, null, null), "3.1 km out")
        assertEquals("2 k to go.", chase(goal = 4_000.0).atKm(2, null, null)!!.text)
        assertNull(chase(goal = 3_000.0).atKm(1, null, null), "a 3 km goal has no last 2 km")
    }

    @Test
    fun `steady says only the distance to go on a goal and never a gap`() {
        val s = ChaseCoach(CoachChoice.steady, 3_000.0, 5_000.0)
        assertNull(s.atKm(2, gap(-20_000), "5K"))
        val toGo = assertNotNull(s.atKm(3, gap(-20_000), "5K"))
        assertEquals("2 k to go.", toGo.text)
        s.said(toGo)
        assertNull(s.atKm(4, gap(-20_000), "5K"))
        assertNull(ChaseCoach(CoachChoice.steady, 3_000.0, null).atKm(4, gap(20_000), "5K"), "a free run: silence")
    }

    // ---- wired into the live coach ----

    private fun ctx(choice: String?, vararg boards: LiveBoard, furthest: Double? = null, muted: Boolean = false) = LiveContext(
        boards = boards.toList(), coachingMuted = muted, builtAtMs = 0, engineVersion = 1,
        coachChoice = choice, monthFurthestM = furthest,
    )

    private fun cross(coach: LiveCoach, km: Int, atMs: Long) =
        coach.onTick(atMs - 500, km * 1_000.0 - 2.0, atMs + 500, km * 1_000.0 + 2.0) { it }

    @Test
    fun `free run with chase - the compare is silent and the overlay steps aside - the chase line rides the km`() {
        val coach = LiveCoach(ctx("chase", fiveK(best)), RunMode.free, null)
        assertNull(cross(coach, 1, 300_000)!!.chase, "km 1")
        val k = assertNotNull(cross(coach, 2, 570_000))
        assertEquals("2 k, 9 minutes 30, pace 4:30.", k.base)
        assertEquals("10 seconds up on your best 5K.", k.chase!!.text)
        assertFalse(k.fire!!.speak)
        assertFalse(k.fire!!.overlay)
    }

    @Test
    fun `free run with no choice - exactly as before`() {
        val coach = LiveCoach(ctx(null, fiveK(best, slower)), RunMode.free, null)
        val k = assertNotNull(cross(coach, 3, 875_000))
        assertNull(k.chase)
        assertTrue(k.fire!!.speak)
        assertTrue(k.fire!!.overlay)
        assertNull(coach.coachChoice)
    }

    @Test
    fun `steady free run - no chase line`() {
        val coach = LiveCoach(ctx("steady", fiveK(best)), RunMode.free, null)
        for (km in 1..4) assertNull(cross(coach, km, km * 280_000L)!!.chase)
        assertEquals(CoachChoice.steady, coach.coachChoice)
    }

    @Test
    fun `muted tips - no chase line`() {
        val coach = LiveCoach(ctx("chase", fiveK(best), muted = true), RunMode.free, null)
        assertNull(cross(coach, 2, 570_000)!!.chase)
    }

    @Test
    fun `km splits off - no chase line because there is no km line to ride`() {
        val coach = LiveCoach(ctx("chase", fiveK(best)), RunMode.free, null)
        coach.kmSplits = false
        assertNull(cross(coach, 2, 570_000)?.chase)
    }

    @Test
    fun `chase on a laps run is off - only Free and goal runs are asked`() {
        val coach = LiveCoach(ctx("chase", fiveK(best)), RunMode.laps, null)
        assertNull(coach.coachChoice)
    }

    @Test
    fun `an unknown choice from a newer build is no choice`() {
        val coach = LiveCoach(ctx("sprint", fiveK(best, slower)), RunMode.free, null)
        assertNull(coach.coachChoice)
        assertTrue(cross(coach, 3, 875_000)!!.fire!!.speak)
    }

    @Test
    fun `km 6 to 10 read the 10K board`() {
        val tenK = LiveBoard(
            "be:10000", "10K", LiveBoardKind.distance, 10_000.0,
            listOf(LiveEntry("t", 0, fromStartSplitsMs = List(10) { (it + 1) * 300_000L }, finalMetric = 3_000_000.0)),
        )
        val coach = LiveCoach(ctx("chase", fiveK(best), tenK), RunMode.free, null)
        assertEquals("30 seconds off your best 10K.", cross(coach, 6, 1_830_000)!!.chase!!.text)
    }

    @Test
    fun `goal run with chase - the goal km compare goes quiet and the chase line comes from the goal board`() {
        val spec = SessionSpec.goalDistance(5_000, "5K")
        val coach = LiveCoach(ctx("chase", fiveK(best)), RunMode.intervals, spec)
        val fire = assertNotNull(coach.atCue(CueKind.projection, 2, 1.0, Phase.work, 0, 570_000, null))
        assertFalse(fire.speak)
        assertFalse(fire.overlay)
        assertEquals("10 seconds up on your best 5K.", coach.chaseAtCue(CueKind.projection, 2, 570_000)!!.text)
        assertEquals("2 k to go, 20 seconds up on your best 5K.", coach.chaseAtCue(CueKind.projection, 3, 850_000)!!.text)
    }

    @Test
    fun `goal chase line needs the km projection cue`() {
        val spec = SessionSpec.goalDistance(5_000, "5K")
        val coach = LiveCoach(ctx("chase", fiveK(best)), RunMode.intervals, spec)
        assertNull(coach.chaseAtCue(CueKind.minuteMark, 2, 570_000))
        assertNull(coach.chaseAtCue(CueKind.projection, null, 570_000))
    }

    @Test
    fun `a goal with no earlier run still says 2 k to go`() {
        val spec = SessionSpec.goalDistance(5_000, "5K")
        val coach = LiveCoach(ctx("chase"), RunMode.intervals, spec)
        assertEquals("2 k to go.", coach.chaseAtCue(CueKind.projection, 3, 850_000)!!.text)
    }

    @Test
    fun `a chase line already journaled is not repeated after a restore`() {
        val fired = listOf(JournalLine.CueFired(0, 0, JournalLine.FiredKind.chase, "furthest", 9, 1))
        val coach = LiveCoach(ctx("chase", fiveK(best), furthest = 8_400.0), RunMode.free, null, fired)
        assertNull(cross(coach, 10, 3_000_000)?.chase)
    }
}
