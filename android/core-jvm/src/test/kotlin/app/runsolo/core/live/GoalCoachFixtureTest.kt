package app.runsolo.core.live

import app.runsolo.core.json.Json
import app.runsolo.core.model.CueKind
import app.runsolo.core.model.LiveContext
import app.runsolo.core.model.Phase
import app.runsolo.core.model.SessionSpec
import app.runsolo.core.model.TargetKind
import app.runsolo.core.record.RecorderCore
import java.io.File
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

/** "New best" against LiveContexts the Dart planner built (`LivePlanner`, goal boards), not hand-made ones. */
class GoalCoachFixtureTest {
    private val fx: Map<String, Any?> = Json.parseObject(File("../../packages/run_engine/test/fixtures/phase4/goal_live_context.json").readText())

    @Suppress("UNCHECKED_CAST")
    private fun ctx(name: String) = LiveContext.fromJson(fx[name] as Map<String, Any?>)

    private fun reached(spec: SessionSpec, ctx: LiveContext, activeMs: Long, distanceM: Double) =
        GoalCoach(spec, ctx).atCue(CueKind.phaseEnd, Phase.cooldown, RecorderCore.StepEnd(activeMs, activeMs, distanceM))!!

    @Test
    fun `board keys match the engine's GoalCatalogue`() {
        @Suppress("UNCHECKED_CAST")
        val rows = fx["boardKeys"] as List<Map<String, Any?>>
        assertTrue(rows.isNotEmpty())
        for (r in rows) {
            val value = (r["value"] as Number).toInt()
            val spec = if (r["kind"] == TargetKind.time.name) SessionSpec.goalTime(value, "g") else SessionSpec.goalDistance(value, "g")
            assertEquals(r["key"], GoalCoach.boardKey(spec.steps.first()), "$r")
        }
    }

    @Test
    fun `a Half finds be 21097 by key and beats the PB only when faster`() {
        val half = SessionSpec.goalDistance(21_098, "Half")
        val ctx = ctx("half")
        assertEquals(21_097.5, ctx.boards.single().targetM)
        assertTrue(reached(half, ctx, 5_999_000, 21_098.0).newBest)
        assertFalse(reached(half, ctx, 6_001_000, 21_098.0).newBest, "the PB is 6000 s, from a run with no full ghost")
    }

    @Test
    fun `30 minutes finds be t1800 and beats the most metres only when farther`() {
        val goal = SessionSpec.goalTime(1_800, "30 min")
        val ctx = ctx("thirtyMin")
        assertTrue(reached(goal, ctx, 1_800_000, 6_301.0).newBest)
        assertFalse(reached(goal, ctx, 1_800_000, 6_299.0).newBest)
    }

    /** #83 review: the event ranks on its course board (the engine's `parkrun:<courseId>`), in ms, before any 5K board. */
    @Test
    fun `the timed 5 km ends against its course board - new best, seconds off, level`() {
        val event = app.runsolo.core.replay.ReplayScenarios.PARKRUN
        val ctx = ctx("event")
        assertTrue(ctx.boards.single().key.startsWith("${SessionSpec.EVENT_ID}:"))
        assertEquals("5K time trial done, 23:50, new best.", reached(event, ctx, 1_430_000, 5_000.0).text)
        assertEquals("5K time trial done, 24:12, 12 seconds off your best.", reached(event, ctx, 1_452_000, 5_000.0).text)
        assertEquals("5K time trial done, 24:00, level with your best.", reached(event, ctx, 1_440_000, 5_000.0).text)
        // A 5K board next to it never wins: the course's is the event's board.
        val with5k = ctx.copy(boards = listOf(ctx.boards.single().copy(key = "be:5000", entries = ctx.boards.single().entries.map { it.copy(finalMetric = 1_000_000.0) })) + ctx.boards)
        assertEquals("5K time trial done, 23:50, new best.", reached(event, with5k, 1_430_000, 5_000.0).text)
    }
}
