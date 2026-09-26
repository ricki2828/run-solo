package app.runsolo.core.live

import app.runsolo.core.json.Json
import app.runsolo.core.model.CueKind
import app.runsolo.core.model.LiveContext
import app.runsolo.core.model.Phase
import app.runsolo.core.model.RunMode
import app.runsolo.core.model.SessionSpec
import app.runsolo.core.record.CueScheduler
import app.runsolo.core.record.CueWords
import app.runsolo.core.record.RecorderCore
import java.io.File
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

/**
 * §G goal km compares: a distance goal's km races the goal's own board at that split, against the
 * LiveContext the Dart planner built (`goal_live_context.json`, the Half: half-2 has 12 km of
 * from-start splits, half-3 and half-1 all 21), and its "100 metres to go" carries the pace.
 */
class GoalKmCompareTest {
    private val fx: Map<String, Any?> = Json.parseObject(File("../../packages/run_engine/test/fixtures/phase4/goal_live_context.json").readText())

    @Suppress("UNCHECKED_CAST")
    private val half = LiveContext.fromJson(fx["half"] as Map<String, Any?>)
    private val halfGoal = SessionSpec.goalDistance(21_098, "Half")

    private fun km(coach: LiveCoach, km: Int, activeMs: Long) =
        coach.atCue(CueKind.projection, km, 5_274_500.0, Phase.work, 0, activeMs, null)

    @Test
    fun `km 5 ranks against the board's splits there - the km replaces On pace for`() {
        val coach = LiveCoach(half, RunMode.intervals, halfGoal)
        // Board km-5 splits: 1 410 000, 1 457 000, 1 480 500 ms.
        val f = assertNotNull(km(coach, 5, 1_450_000))
        assertEquals("be:21097", f.key)
        assertEquals(2, f.result.rank)
        assertEquals(4, f.result.of)
        assertEquals("5 k.", f.base)
        assertEquals("Number 2 of 4, 40 seconds off your best.", f.text)
        assertTrue(f.speak)
        val line = CueComposer.compose(f.base, f.text).text!!
        assertEquals("5 k. Number 2 of 4, 40 seconds off your best.", line)
        assertTrue(CueComposer.words(line) <= CueComposer.MAX_WORDS)
    }

    @Test
    fun `ahead of every run - best so far`() {
        val f = assertNotNull(km(LiveCoach(half, RunMode.intervals, halfGoal), 1, 270_000))
        assertEquals(1, f.result.rank)
        assertEquals("Best of 4 so far, 12 seconds up.", f.text)
    }

    @Test
    fun `an entry without that km sits it out`() {
        val f = assertNotNull(km(LiveCoach(half, RunMode.intervals, halfGoal), 13, 3_700_000))
        assertEquals(3, f.result.of, "half-2 stops at km 12")
    }

    @Test
    fun `each km once, and muted keeps the overlay and the cue's own words`() {
        val coach = LiveCoach(half, RunMode.intervals, halfGoal)
        assertNotNull(km(coach, 2, 580_000))
        assertNull(km(coach, 2, 580_000), "never twice")
        coach.muted = true
        val f = assertNotNull(km(coach, 3, 870_000))
        assertFalse(f.speak)
    }

    @Test
    fun `no board for the goal, no live context, a time goal or past the goal - no compare`() {
        assertNull(km(LiveCoach(null, RunMode.intervals, halfGoal), 5, 1_450_000))
        val tenK = SessionSpec.goalDistance(10_000, "10K")
        assertNull(km(LiveCoach(half, RunMode.intervals, tenK), 5, 1_450_000), "matched by key, the Half's board is not the 10K's")
        val thirty = SessionSpec.goalTime(1_800, "30 min")
        assertNull(km(LiveCoach(half, RunMode.intervals, thirty), 5, 1_450_000))
        val coach = LiveCoach(half, RunMode.intervals, halfGoal)
        coach.goalReachedAt(21_098.0, 5_274_000)
        assertNull(km(coach, 5, 1_450_000))
    }

    @Test
    fun `the scheduler drops a goal's km within 250 m of the goal - not for other distance steps`() {
        fun kms(points: List<CueScheduler.CuePoint>) = points.filter { it.kind == CueKind.projection }.map { (it.at / 1_000).toInt() }
        assertEquals((1..20).toList(), kms(CueScheduler.distance(21_098, goal = true)), "km 21 is 98 m out")
        assertEquals((1..21).toList(), kms(CueScheduler.distance(21_098)))
        assertEquals((1..41).toList(), kms(CueScheduler.distance(42_195, goal = true)), "km 42 is 195 m out")
        assertEquals((1..9).toList(), kms(CueScheduler.distance(10_000, goal = true)))
        assertEquals((1..12).toList(), kms(CueScheduler.distance(12_300, goal = true)), "300 m out stays")
    }

    @Test
    fun `a goal's to-go line carries the projected finish - one line, not two`() {
        val core = RecorderCore(RunMode.intervals, halfGoal)
        core.start(1_000L)
        val out = ArrayList<RecorderCore.Output>()
        var d = 0.0
        for (i in 1..5_300) {
            d += 4.0
            out.addAll(core.tick(1_000L + i * 1_000L, d))
        }
        val cues = out.filterIsInstance<RecorderCore.Output.Cue>()
        val toGo = cues.single { it.kind == CueKind.distanceToGo }
        assertNotNull(toGo.value)
        assertEquals(21_098 / 4.0 * 1_000, toGo.value!!, 2_000.0)
        val line = CueWords.text(toGo.kind, toGo.value, halfGoal, Phase.work, 1, 0, null)!!
        assertTrue(line.startsWith("100 metres to go, on pace for 1:27:5"), line)
        assertFalse(cues.any { it.kind == CueKind.projection && it.index == 21 })
        // Any other distance step keeps the plain line.
        assertEquals("100 metres to go", CueWords.text(CueKind.distanceToGo, null, halfGoal, Phase.work, 1, 0, null))
    }
}
