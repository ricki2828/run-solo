package app.runsolo.core.record

import app.runsolo.core.model.CueKind
import app.runsolo.core.model.Phase
import app.runsolo.core.model.RecoveryStyle
import app.runsolo.core.model.SessionSpec
import app.runsolo.core.model.Step
import app.runsolo.core.model.StepKind
import app.runsolo.core.model.TargetKind
import kotlin.test.Test
import kotlin.test.assertEquals

/** The ten-seconds cue with voice coaching: it names what comes next. Without coaching it is unchanged. */
class CueWordsNextStepTest {
    private val eight400 = SessionSpec.norwegian4x4().copy(
        templateId = "400s", name = "8 × 400 m", hrBand = null,
        steps = (1..8).flatMap { r ->
            listOfNotNull(
                Step(StepKind.work, TargetKind.time, 60, RecoveryStyle.run, r),
                if (r < 8) Step(StepKind.recovery, TargetKind.distance, 200, RecoveryStyle.jog, r) else null,
            )
        },
    )

    private fun ten(spec: SessionSpec?, phase: Phase, step: Int?, coach: Boolean = true) =
        CueWords.text(CueKind.tenSeconds, null, spec, phase, 1, step, null, coach)

    @Test
    fun `work into a distance jog recovery`() {
        assertEquals("Ten seconds, then 200 metres jog", ten(eight400, Phase.work, 0))
    }

    @Test
    fun `recovery into the next rep, and into the last rep`() {
        assertEquals("Ten seconds, then rep 2", ten(eight400, Phase.recovery, 1))
        assertEquals("Ten seconds, then last rep", ten(eight400, Phase.recovery, 13))
    }

    @Test
    fun `time recoveries by style, equal-time recovery follows the work step`() {
        val s = SessionSpec.norwegian4x4(3, 240, 90)
        assertEquals("Ten seconds, then 1 minute 30 jog", ten(s, Phase.work, 0))
        val walk = s.copy(steps = s.steps.map { if (it.kind == StepKind.recovery) it.copy(style = RecoveryStyle.walk, value = 30) else it })
        assertEquals("Ten seconds, then 30 seconds walk", ten(walk, Phase.work, 0))
        val stand = s.copy(steps = s.steps.map { if (it.kind == StepKind.recovery) it.copy(style = RecoveryStyle.stand, value = 45) else it })
        assertEquals("Ten seconds, then 45 seconds stand", ten(stand, Phase.work, 0))
        val equal = s.copy(steps = s.steps.map { if (it.kind == StepKind.recovery) it.copy(target = TargetKind.equalToPreviousWork, value = 0) else it })
        assertEquals("Ten seconds, then 4 minutes jog", ten(equal, Phase.work, 0))
    }

    @Test
    fun `warm-up into the first rep, the last rep into the cool-down`() {
        assertEquals("Ten seconds, then rep 1", ten(SessionSpec.norwegian4x4(), Phase.warmup, null))
        assertEquals("Ten seconds, then cool down", ten(SessionSpec.norwegian4x4(), Phase.work, 6))
    }

    @Test
    fun `goals, Cooper and Free runs say plain ten seconds, and so does everything with coaching off`() {
        assertEquals("Ten seconds", ten(SessionSpec.goalTime(1_800, "30 min"), Phase.work, 0))
        assertEquals("Ten seconds", ten(SessionSpec.COOPER, Phase.work, 0))
        assertEquals("Ten seconds", ten(null, Phase.none, null))
        assertEquals("Ten seconds", ten(eight400, Phase.work, 0, coach = false))
    }
}
