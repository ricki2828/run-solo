package app.runsolo.core.live

import app.runsolo.core.model.LiveTarget
import kotlin.test.Test
import kotlin.test.assertEquals

class GoalMarginTest {
    private val t = 1_470_000L // 24:30

    @Test
    fun `ahead is the even split minus the time taken`() {
        val target = LiveTarget(5_000.0, t, predicted = false)
        assertEquals(30_000L, GoalMargin.aheadMs(target, 2_000.0, 558_000))
        assertEquals(-6_000L, GoalMargin.aheadMs(target, 1_000.0, 300_000))
    }

    @Test
    fun `the new target line names the distance and the whole minutes`() {
        assertEquals("New target: 8 k in 52 minutes.", GoalMargin.newTargetLine(8_000.0, 3_120_000))
        assertEquals("New target: 5 k in 1 minute.", GoalMargin.newTargetLine(5_000.0, 60_000))
        assertEquals("New target: 21.1 k in 2 hours.", GoalMargin.newTargetLine(21_097.0, 7_200_000))
        assertEquals("New target: 10 k in 1 hour 5 minutes.", GoalMargin.newTargetLine(10_000.0, 3_900_000))
    }

    @Test
    fun `the trend has a dead band of 3 s`() {
        assertEquals(MarginTrend.steady, GoalMargin.trend(2_999))
        assertEquals(MarginTrend.steady, GoalMargin.trend(-2_999))
        assertEquals(MarginTrend.growing, GoalMargin.trend(3_000))
        assertEquals(MarginTrend.shrinking, GoalMargin.trend(-3_000))
    }

    @Test
    fun `phrases name the target and describe the trend`() {
        assertEquals("20 seconds ahead of 24:30, margin shrinking", GoalMargin.phrase(20_000, -8_000, t))
        assertEquals("20 seconds ahead of 24:30, margin growing", GoalMargin.phrase(20_000, 8_000, t))
        assertEquals("10 seconds behind 24:30, holding", GoalMargin.phrase(-10_000, 1_000, t))
        assertEquals("10 seconds behind 24:30, slipping", GoalMargin.phrase(-10_000, -8_000, t))
        assertEquals("10 seconds behind 24:30, closing", GoalMargin.phrase(-10_000, 8_000, t))
        assertEquals("On 24:30 pace", GoalMargin.phrase(2_999, 1_000, t))
        assertEquals("On 24:30 pace, slipping", GoalMargin.phrase(2_999, -8_000, t))
        assertEquals("On 24:30 pace, gaining", GoalMargin.phrase(2_999, 8_000, t))
        assertEquals("level with 24:30, slipping", GoalMargin.promptPhrase(1_000, -8_000, t))
        assertEquals("level with 24:30", GoalMargin.promptPhrase(1_000, 0, t))
        assertEquals("20 seconds ahead of 24:30", GoalMargin.phrase(20_000, null, t))
    }
}
