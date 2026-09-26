package app.runsolo.core.record

import app.runsolo.core.model.CueKind
import app.runsolo.core.model.CueProfile
import app.runsolo.core.model.Phase
import app.runsolo.core.model.RecoveryStyle
import app.runsolo.core.model.SessionSpec
import app.runsolo.core.model.Step
import app.runsolo.core.model.StepKind
import app.runsolo.core.model.TargetKind
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull

class CueWordsTest {
    private val eight400 = SessionSpec.norwegian4x4().copy(
        templateId = "400s", name = "8 × 400 m", hrBand = null,
        steps = (1..8).flatMap { r ->
            listOfNotNull(
                Step(StepKind.work, TargetKind.distance, 400, RecoveryStyle.run, r),
                if (r < 8) Step(StepKind.recovery, TargetKind.time, 90, RecoveryStyle.stand, r) else null,
            )
        },
    )

    private fun say(kind: CueKind, spec: SessionSpec?, phase: Phase, rep: Int, step: Int?, value: Double? = null, index: Int? = null) =
        CueWords.text(kind, value, spec, phase, rep, step, index)

    @Test
    fun `starts - distance rep, time rep, recovery styles, short, Cooper`() {
        assertEquals("Rep 3 of 8, 400 metres", say(CueKind.start, eight400, Phase.work, 3, 4))
        assertEquals("Stand", say(CueKind.start, eight400, Phase.recovery, 3, 5))
        assertEquals("Go. Rep 2", say(CueKind.start, SessionSpec.norwegian4x4(), Phase.work, 2, 2))
        assertEquals("Recover", say(CueKind.start, SessionSpec.norwegian4x4(), Phase.recovery, 2, 3))
        val short = SessionSpec.norwegian4x4(4, 30, 30).copy(cueProfile = CueProfile.short)
        assertEquals("Go", say(CueKind.start, short, Phase.work, 1, 0))
        assertEquals("Easy", say(CueKind.start, short, Phase.recovery, 1, 1))
        assertEquals("Twelve minutes. Go", say(CueKind.start, SessionSpec.COOPER, Phase.work, 1, 0))
        assertNull(say(CueKind.start, SessionSpec.norwegian4x4(), Phase.cooldown, 4, null))
    }

    @Test
    fun `ends, distance to go, last rep, minutes, countdown`() {
        assertNull(say(CueKind.phaseEnd, eight400, Phase.recovery, 1, 1))
        assertEquals("Done. Cool down", say(CueKind.phaseEnd, eight400, Phase.cooldown, 8, null))
        assertEquals("Cool-down done", say(CueKind.phaseEnd, eight400, Phase.cooldown, 8, null, CueWords.COOLDOWN_OVER))
        assertEquals("Time. Cool down", say(CueKind.phaseEnd, SessionSpec.COOPER, Phase.cooldown, 1, null))
        assertEquals("100 metres to go", say(CueKind.distanceToGo, eight400, Phase.work, 1, 0))
        // The last rep says so in its start line; the lastRep cue is silent (#79 review).
        assertNull(say(CueKind.lastRep, eight400, Phase.work, 8, 14))
        assertEquals("Last rep, 8 of 8, 400 metres", say(CueKind.start, eight400, Phase.work, 8, 14))
        assertEquals("Go. Last rep, 4 of 4", say(CueKind.start, SessionSpec.norwegian4x4(), Phase.work, 4, 6))
        assertEquals("Last rep. Go", say(CueKind.start, SessionSpec.norwegian4x4(4, 30, 30).copy(cueProfile = CueProfile.short), Phase.work, 4, 6))
        assertEquals("1 minute", say(CueKind.minuteMark, SessionSpec.COOPER, Phase.work, 1, 0, 1.0))
        assertEquals("7 minutes", say(CueKind.minuteMark, SessionSpec.COOPER, Phase.work, 1, 0, 7.0))
        assertNull(say(CueKind.countdown, SessionSpec.COOPER, Phase.work, 1, 0))
        assertEquals("Run saved", say(CueKind.stop, null, Phase.none, 0, null))
    }

    @Test
    fun `projections - parkrun finish time, Cooper minute with the projected distance and VO2`() {
        val parkrun = eight400.copy(templateId = "parkrun", steps = listOf(Step(StepKind.work, TargetKind.distance, 5000, RecoveryStyle.run, 1)))
        assertEquals("On pace for 24:10", say(CueKind.projection, parkrun, Phase.work, 1, 0, 1_450_000.0))
        assertEquals("On pace for 1:02:05", say(CueKind.projection, parkrun, Phase.work, 1, 0, 3_725_000.0))
        // 2,800 m → VO2 (2800 − 504.9) / 44.73 = 51.3 (the CO1 table's cue).
        assertEquals("5 minutes. Heading for about 2,800. VO2 about 51.", say(CueKind.projection, SessionSpec.COOPER, Phase.work, 1, 0, 2_801.0, 5))
        assertEquals("2 minutes. Heading for about 3,690. VO2 about 71.", say(CueKind.projection, SessionSpec.COOPER, Phase.work, 1, 0, 3_690.9, 2))
    }

    @Test
    fun `a goal or the timed 5 km starts with its name, never Rep 1 of 1`() {
        fun start(spec: SessionSpec) = CueWords.text(CueKind.start, null, spec, Phase.work, 1, 0)
        assertEquals("10K. Go", start(SessionSpec.goalDistance(10_000, "10K")))
        assertEquals("Half marathon. Go", start(SessionSpec.goalDistance(21_097, "Half marathon")))
        assertEquals("30 min. Go", start(SessionSpec.goalTime(1_800, "30 min")))
        assertEquals("5K time trial. Go", start(app.runsolo.core.replay.ReplayScenarios.PARKRUN))
        assertEquals("Rep 1 of 8, 400 metres", start(eight400), "a one-of-many distance rep is unchanged")
        // The engine's spoken name wins over the compact UI name.
        assertEquals("30 minutes. Go", start(SessionSpec.goalTime(1_800, "30 min").copy(spokenName = "30 minutes")))
        assertEquals("10 K. Go", start(SessionSpec.goalDistance(10_000, "10K").copy(spokenName = "10 K")))
    }

    @Test
    fun `the goal-reached line says the spoken name`() {
        val spec = SessionSpec.goalTime(1_800, "30 min").copy(spokenName = "30 minutes")
        val g = app.runsolo.core.live.GoalCoach(spec, null).atCue(CueKind.phaseEnd, Phase.cooldown, RecorderCore.StepEnd(0, 1_800_000, 7_210.0))
        assertEquals("30 minutes done, 7.21 km.", g!!.text)
    }

    @Test
    fun `spokenName - after name in the session JSON, left out when null, round trips`() {
        val plain = SessionSpec.goalDistance(10_000, "10K")
        assertEquals(false, "spokenName" in plain.toJson(), "older files stay byte for byte")
        val spoken = plain.copy(spokenName = "10 K")
        assertEquals(listOf("templateId", "templateVersion", "name", "spokenName", "warmupSeconds"), spoken.toJson().keys.take(5))
        assertEquals(spoken, SessionSpec.fromJson(spoken.toJson()))
        assertEquals(plain, SessionSpec.fromJson(plain.toJson()))
    }

    /** The timed 5 km's end line, pinned (lead 26-Sep): the result against its board, never "Cool down". */
    @Test
    fun `the timed 5 km ends with its result line - new best, seconds off, level, no board`() {
        val event = app.runsolo.core.replay.ReplayScenarios.PARKRUN
        fun board(vararg ms: Long) = app.runsolo.core.model.LiveContext(
            boards = listOf(
                app.runsolo.core.model.LiveBoard(
                    "${SessionSpec.EVENT_ID}:c-1", "5K time trial", app.runsolo.core.model.LiveBoardKind.distance, 5_000.0,
                    ms.mapIndexed { i, m -> app.runsolo.core.model.LiveEntry("r$i", 0, fromStartSplitsMs = List(5) { k -> m * (k + 1) / 5 }, finalMetric = m.toDouble()) },
                ),
            ),
            builtAtMs = 0, engineVersion = 3,
        )
        fun end(ctx: app.runsolo.core.model.LiveContext?, activeMs: Long) =
            app.runsolo.core.live.GoalCoach(event, ctx).atCue(CueKind.phaseEnd, Phase.cooldown, RecorderCore.StepEnd(0, activeMs, 5_000.0))!!.text
        assertNull(CueWords.text(CueKind.phaseEnd, null, event, Phase.cooldown, 1, null), "no \"Done. Cool down\": the run stops")
        assertEquals("5K time trial done, 23:40, new best.", end(board(1_440_000, 1_500_000), 1_420_000))
        assertEquals("5K time trial done, 23:52, 12 seconds off your best.", end(board(1_420_000, 1_500_000), 1_432_000))
        assertEquals("5K time trial done, 23:41, 1 second off your best.", end(board(1_420_000), 1_421_000))
        assertEquals("5K time trial done, 26:17, 2 minutes 37 off your best.", end(board(1_420_000), 1_577_000))
        assertEquals("5K time trial done, 23:40, level with your best.", end(board(1_420_000), 1_420_000))
        assertEquals("5K time trial done, 23:40.", end(null, 1_420_000))
        assertEquals("5K time trial done, 23:40.", end(board(1_440_000).copy(boards = emptyList()), 1_420_000))
    }
}
