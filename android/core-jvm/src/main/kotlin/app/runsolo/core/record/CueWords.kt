package app.runsolo.core.record

import app.runsolo.core.live.CooperProjection
import app.runsolo.core.model.CueKind
import app.runsolo.core.model.CueProfile
import app.runsolo.core.model.Phase
import app.runsolo.core.model.RecoveryStyle
import app.runsolo.core.model.SessionSpec
import app.runsolo.core.model.StepKind
import app.runsolo.core.model.TargetKind
import java.util.Locale
import kotlin.math.roundToInt
import kotlin.math.roundToLong

/**
 * What a cue says (Phase 3 §3.6), kept out of the Android `CuePlayer` so the wording is
 * JVM-tested. Null = no speech (the player still vibrates, and a `countdown` is three tones).
 * Called after the core applied the cue's outputs, so [phase], [repIndex] and [stepIndex]
 * describe what comes next at a `start` or `phaseEnd`.
 */
object CueWords {
    /** [RecorderCore.Output.Cue.value] of the `phaseEnd` that closes a fixed cool-down. */
    const val COOLDOWN_OVER = 1.0

    fun text(
        kind: CueKind,
        value: Double?,
        spec: SessionSpec?,
        phase: Phase,
        repIndex: Int,
        stepIndex: Int?,
        index: Int? = null,
    ): String? {
        val step = stepIndex?.let { spec?.steps?.getOrNull(it) }
        val cooper = spec?.cueProfile == CueProfile.cooper
        val short = spec?.cueProfile == CueProfile.short
        return when (kind) {
            CueKind.start -> when {
                step == null -> null
                step.kind == StepKind.work && cooper -> "Twelve minutes. Go"
                // A goal or the timed 5 km is one step, not reps: say what it is ("10K. Go", "30 min. Go").
                step.kind == StepKind.work && (spec!!.isGoal || spec.isEvent) -> "${spec.name}. Go"
                step.kind == StepKind.work && short -> "Go"
                step.kind == StepKind.work && step.target == TargetKind.distance ->
                    "Rep $repIndex of ${spec!!.reps}, ${metres(step.value.toDouble())}"
                step.kind == StepKind.work -> "Go. Rep $repIndex"
                short -> "Easy"
                else -> when (step.style) {
                    RecoveryStyle.walk -> "Walk"
                    RecoveryStyle.stand -> "Stand"
                    RecoveryStyle.jog, RecoveryStyle.run -> "Recover"
                }
            }
            CueKind.halfway -> "Halfway"
            CueKind.thirtySeconds -> "Thirty seconds"
            // The next `start` cue says what comes; only the end of the last part is spoken.
            CueKind.phaseEnd -> when {
                value == COOLDOWN_OVER -> "Cool-down done"
                phase != Phase.cooldown -> null
                spec?.isGoal == true -> null // the goal-reached line (GoalCoach) says it
                cooper -> "Time. Cool down"
                else -> "Done. Cool down"
            }
            CueKind.stop -> "Run saved"
            CueKind.distanceToGo -> "100 metres to go"
            CueKind.lastRep -> "Last rep"
            CueKind.minuteMark -> value?.let { m -> val n = m.roundToInt(); if (n == 1) "1 minute" else "$n minutes" }
            CueKind.countdown -> null // three tones, no words
            // Cooper: "5 minutes. Heading for about 2,740. VO2 about 50." (index = the minute); the
            // rank against past tests is LiveCoach's, at 3, 6 and 9 minutes.
            CueKind.projection -> value?.let { v -> if (cooper && index != null) CooperProjection.cue(index, v) else if (cooper) null else "On pace for ${clock(v)}" }
        }
    }

    /** Cooper (1968): VO2max ≈ (d − 504.9) / 44.73, d in metres over 12 minutes. */
    fun cooperVo2(metres: Double): Double = CooperProjection.vo2(metres)

    private fun metres(m: Double): String =
        if (m >= 1_000 && m % 1_000 == 0.0) "${(m / 1_000).toInt()} kilometres" else "${m.toInt()} metres"

    /** mm:ss (h:mm:ss past an hour) of a duration in ms. */
    fun clock(ms: Double): String {
        val s = (ms / 1_000).roundToLong()
        val h = s / 3_600
        val m = (s % 3_600) / 60
        val sec = s % 60
        return if (h > 0) String.format(Locale.US, "%d:%02d:%02d", h, m, sec) else String.format(Locale.US, "%d:%02d", m, sec)
    }
}
