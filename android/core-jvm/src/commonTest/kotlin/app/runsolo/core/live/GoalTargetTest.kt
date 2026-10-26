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
