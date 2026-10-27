package app.runsolo.core.live

import app.runsolo.core.model.CueKind
import app.runsolo.core.model.LiveContext
import app.runsolo.core.model.LiveTarget
import app.runsolo.core.model.RunMode
import app.runsolo.core.model.SessionSpec
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

/** Where the goal-time wording is switched on: only a distance goal whose target is for the goal's own distance. */
class GoalTargetTest {
    // Production targets are always predictions (StartTarget.forSession).
    private val target = LiveTarget(5_000.0, 1_470_000, predicted = true)

    private fun ctx(t: LiveTarget? = target, choice: String? = "chase") = LiveContext(
        boards = emptyList(), target = t, coachingMuted = false, builtAtMs = 0, engineVersion = 1, coachChoice = choice,
    )

    private val fiveK = SessionSpec.goalDistance(5_000, "5K")

    @Test
    fun `a distance goal with a target for its own distance has a goal target and a goal progress`() {
        val c = LiveCoach(ctx(), RunMode.intervals, fiveK)
        assertEquals(target, c.goalTarget)
        val g = assertNotNull(c.goalProgress(2_000.0, 558_000))
        assertEquals(2_000.0, g.distanceM)
        assertEquals(558_000L, g.elapsedMs)
        assertEquals(30_000L, GoalMargin.aheadMs(g.target, g.distanceM, g.elapsedMs))
    }

    @Test
    fun `ease off re-aims the goal time to the projected finish rounded up to the next whole minute`() {
        val c = LiveCoach(ctx(LiveTarget(8_000.0, 2_220_000, predicted = true)), RunMode.intervals, SessionSpec.goalDistance(8_000, "8K"))
        // 2 km in 746 s: 8 km projects to 2984 s = 49:44, so 50 minutes.
        assertEquals(3_000_000L, c.rebaseGoal(2_000.0, 746_000))
        val t = assertNotNull(c.goalTarget)
        assertEquals(3_000_000L, t.targetMs)
        assertEquals(false, t.predicted)
        assertEquals(3_000_000L, assertNotNull(c.goalProgress(2_100.0, 780_000)).target.targetMs)
        assertEquals(true, c.goalRebased)
    }

    @Test
    fun `a second ease off re-aims again and an exact minute stays put`() {
        val c = LiveCoach(ctx(LiveTarget(8_000.0, 2_220_000, predicted = true)), RunMode.intervals, SessionSpec.goalDistance(8_000, "8K"))
        assertEquals(3_000_000L, c.rebaseGoal(2_000.0, 750_000)) // 3000 s exactly
        assertEquals(3_360_000L, c.rebaseGoal(4_000.0, 1_660_000)) // 3320 s -> 56 min
    }

    @Test
    fun `no re-aim off a few hundred metres or after the goal or on a run without a goal time`() {
        val c = LiveCoach(ctx(), RunMode.intervals, fiveK)
        assertNull(c.rebaseGoal(300.0, 100_000))
        assertNull(LiveCoach(ctx(), RunMode.free, null).rebaseGoal(2_000.0, 600_000))
        c.goalReachedAt(5_000.0, 1_400_000)
        assertNull(c.rebaseGoal(5_000.0, 1_400_000))
        assertEquals(false, c.goalRebased)
    }

    @Test
    fun `a restore keeps the re-aimed time and the PB chase stays silent after it`() {
        val c = LiveCoach(ctx(), RunMode.intervals, fiveK)
        c.restoreRebase(1_800_000L)
        assertEquals(1_800_000L, c.goalTarget?.targetMs)
        assertNull(c.chaseAtCue(CueKind.projection, 2, 600_000))
        // The cue is silent but the prompts still get their km facts, against the re-aimed clock.
        val f = assertNotNull(c.takeKmFacts())
        assertEquals(1_800_000L, f.goalTimeMs)
        assertNull(f.gapMs)
        assertEquals(600_000L - (1_800_000L * 2 / 5), f.behindTargetMs)
    }

    @Test
    fun `ease off then later km then last 2 km prompt and a second re-aim all read the new time`() {
        val c = LiveCoach(ctx(LiveTarget(10_000.0, 2_400_000, predicted = true)), RunMode.free, SessionSpec.goalDistance(10_000, "10K"))
        val p = CoachPrompter()
        // Runs one km: the cue's facts reach the prompter as the session does it. [elapsedMs] = active ms at the km.
        fun km(k: Int, elapsedMs: Long): Prompt? {
            c.chaseAtCue(CueKind.projection, k, elapsedMs)
            val f = assertNotNull(c.takeKmFacts(), "facts at km $k")
            return p.atKm(f, elapsedMs, k * 1_000.0 + 2)
        }
        fun ease(q: Prompt, distanceM: Double, elapsedMs: Long): Long {
            p.opened(q, distanceM)
            val a = assertNotNull(p.answer(q.id, 1, PromptSource.tap, q.openedAtMs + 3_000))
            assertEquals(PromptChoice.ease, a.choice)
            val re = assertNotNull(c.rebaseGoal(distanceM, elapsedMs))
            p.retargeted()
            return re
        }
        // 300 s/km against 240: behind and losing ground, so km 2 asks.
        assertNull(km(1, 300_000))
        val first = assertNotNull(km(2, 600_000))
        assertEquals(PromptKind.behindTarget, first.kind)
        assertEquals(3_000_000L, ease(first, 2_002.0, 600_000)) // 3000 s: 50 minutes
        // 330 s/km from here: behind the new clock and growing, so km 4 asks again, naming 50 minutes.
        assertNull(km(3, 930_000))
        val second = assertNotNull(km(4, 1_260_000))
        assertEquals(PromptKind.behindTarget, second.kind)
        assertTrue(second.text.contains("behind 50 minutes"), second.text)
        assertEquals(3_180_000L, ease(second, 4_002.0, 1_260_000)) // 3150 s rounds up to 53 minutes
        for (k in 5..7) assertNull(km(k, 1_260_000L + (k - 4) * 330_000))
        val last = assertNotNull(km(8, 2_580_000))
        assertEquals(PromptKind.last2k, last.kind)
        assertTrue(last.text.contains("over 53 minutes"), last.text)
        assertTrue(last.text.endsWith("Faster finish, or same pace?"), last.text)
    }

    @Test
    fun `every other run has none`() {
        assertNull(LiveCoach(ctx(), RunMode.intervals, SessionSpec.goalTime(1_800, "30 min")).goalTarget, "a time goal")
        assertNull(LiveCoach(ctx(), RunMode.intervals, fiveK.copy(templateId = SessionSpec.EVENT_ID)).goalTarget, "the timed 5 km event")
        assertNull(LiveCoach(ctx(), RunMode.intervals, SessionSpec.norwegian4x4()).goalTarget, "an interval session")
        assertNull(LiveCoach(ctx(), RunMode.free, null).goalTarget, "a Free run")
        assertNull(LiveCoach(ctx(), RunMode.trail, null).goalTarget, "a Trail run")
        assertNull(LiveCoach(ctx(t = null), RunMode.intervals, fiveK).goalTarget, "no target")
        assertNull(LiveCoach(ctx(LiveTarget(10_000.0, 3_000_000, true)), RunMode.intervals, fiveK).goalTarget, "a target for another distance")
        assertNull(LiveCoach(null, RunMode.intervals, fiveK).goalTarget, "no context")
        assertNull(LiveCoach(ctx(), RunMode.free, null).goalProgress(2_000.0, 558_000))
    }

    @Test
    fun `the goal is over at the line - no goal progress in the cool-down`() {
        val c = LiveCoach(ctx(), RunMode.intervals, fiveK)
        c.goalReachedAt(5_000.0, 1_400_000)
        assertNull(c.goalProgress(5_100.0, 1_430_000))
    }

    @Test
    fun `the goal time reaches the prompt facts for chase and Steady and a Free run leaves none`() {
        for (choice in listOf("chase", "steady")) {
            val c = LiveCoach(ctx(choice = choice), RunMode.intervals, fiveK)
            c.chaseAtCue(CueKind.projection, 3, 850_000)
            val f = assertNotNull(c.takeKmFacts(), choice)
            assertEquals(1_470_000L, f.goalTimeMs, choice)
            // Km 3 at 14:10 against the even split 14:42: 32 s ahead (behind is negative).
            assertEquals(-32_000L, f.behindTargetMs, choice)
        }
        val free = LiveCoach(ctx(), RunMode.free, null)
        free.onTick(289_500, 998.0, 290_500, 1_002.0) { it }
        assertNull(free.takeKmFacts()?.goalTimeMs)
    }
}
