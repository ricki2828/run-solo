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
        assertEquals("Last rep", say(CueKind.lastRep, eight400, Phase.work, 8, 14))
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
}
