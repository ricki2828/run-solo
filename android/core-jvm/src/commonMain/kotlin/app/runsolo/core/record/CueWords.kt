package app.runsolo.core.record

import app.runsolo.core.live.CooperProjection
import app.runsolo.core.model.CueKind
import app.runsolo.core.model.CueProfile
import app.runsolo.core.model.Phase
import app.runsolo.core.model.RecoveryStyle
import app.runsolo.core.model.SessionSpec
import app.runsolo.core.model.StepKind
import app.runsolo.core.model.TargetKind
import kotlin.math.abs
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

    /** The Ready screen's spoken countdown: 3, 2, 1, then 0 = "Go" (null for any other number). */
    fun countdownBeat(beat: Int): String? = when (beat) {
        3 -> "Three"
        2 -> "Two"
        1 -> "One"
        0 -> "Go"
        else -> null
    }

    fun text(
        kind: CueKind,
        value: Double?,
        spec: SessionSpec?,
        phase: Phase,
        repIndex: Int,
        stepIndex: Int?,
        index: Int? = null,
        coach: Boolean = false,
    ): String? {
        val step = stepIndex?.let { spec?.steps?.getOrNull(it) }
        val cooper = spec?.cueProfile == CueProfile.cooper
        val short = spec?.cueProfile == CueProfile.short
        return when (kind) {
            CueKind.start -> when {
                step == null -> null
                step.kind == StepKind.work && cooper -> "Twelve minutes. Go"
                // A goal or the timed 5 km is one step, not reps: say what it is ("10 K. Go", "30 minutes. Go").
                step.kind == StepKind.work && (spec!!.isGoal || spec.isEvent) -> "${spec.spoken}. Go"
                // The last rep says so in its own start line (#79 review: "Rep 8 of 8" + "Last rep"
                // were two lines at once); the `lastRep` cue itself is silent.
                step.kind == StepKind.work && short -> if (lastRep(spec!!, repIndex)) "Last rep. Go" else "Go"
                step.kind == StepKind.work && step.target == TargetKind.distance ->
                    (if (lastRep(spec!!, repIndex)) "Last rep, $repIndex of ${spec.reps}, " else "Rep $repIndex of ${spec.reps}, ") +
                        metres(step.value.toDouble())
                step.kind == StepKind.work -> if (lastRep(spec!!, repIndex)) "Go. Last rep, $repIndex of ${spec.reps}" else "Go. Rep $repIndex"
                short -> "Easy"
                else -> when (step.style) {
                    RecoveryStyle.walk -> "Walk"
                    RecoveryStyle.stand -> "Stand"
                    RecoveryStyle.jog, RecoveryStyle.run -> "Recover"
                }
            }
            CueKind.halfway -> "Halfway"
            CueKind.thirtySeconds -> "Thirty seconds"
            // Voice coaching names what comes next ("Ten seconds, then 200 metres jog"); never in a replay.
            CueKind.tenSeconds -> (if (coach) nextStep(spec, phase, stepIndex) else null)?.let { "Ten seconds, then $it" } ?: "Ten seconds"
            // The next `start` cue says what comes; only the end of the last part is spoken.
            CueKind.phaseEnd -> when {
                value == COOLDOWN_OVER -> "Cool-down done"
                phase != Phase.cooldown -> null
                spec?.isGoal == true || spec?.isEvent == true -> null // the goal-reached line (GoalCoach) says it
                cooper -> "Time. Cool down"
                else -> "Done. Cool down"
            }
            CueKind.stop -> "Run saved"
            // A goal's merges the pace line: "100 metres to go, on pace for 1:28:00" (§G).
            CueKind.distanceToGo -> if (value != null && spec?.isGoal == true) "100 metres to go, on pace for ${clock(value)}" else "100 metres to go"
            CueKind.lastRep -> null
            CueKind.minuteMark -> value?.let { m -> val n = m.roundToInt(); if (n == 1) "1 minute" else "$n minutes" }
            CueKind.countdown -> null // three tones, no words
            // Cooper: "5 minutes. Heading for about 2.74km. VO2 about 50." (index = the minute); the
            // rank against past tests is LiveCoach's, at 3, 6 and 9 minutes.
            CueKind.projection -> value?.let { v -> if (cooper && index != null) CooperProjection.cue(index, v) else if (cooper) null else "On pace for ${clock(v)}" }
        }
    }

    /**
     * What follows the current part, for the ten-seconds cue with voice coaching on: "200 metres jog",
     * "30 seconds walk", "rep 3", "last rep", "cool down". Null when nothing is said (goals, events,
     * Cooper, Free runs, the last part of a run). A recovery that is zero seconds long is skipped.
     */
    fun nextStep(spec: SessionSpec?, phase: Phase, stepIndex: Int?): String? {
        spec ?: return null
        if (spec.isGoal || spec.isEvent || spec.cueProfile == CueProfile.cooper) return null
        val from = when (phase) {
            Phase.warmup -> 0
            Phase.work, Phase.recovery -> (stepIndex ?: return null) + 1
            else -> return null
        }
        var i = from
        while (true) {
            val next = spec.steps.getOrNull(i) ?: return if (phase == Phase.cooldown || spec.cooldownSeconds == 0) null else "cool down"
            if (next.kind == StepKind.recovery && next.target == TargetKind.time && next.value == 0) { i++; continue }
            return when (next.kind) {
                StepKind.work -> if (spec.reps > 1 && next.rep == spec.reps) "last rep" else if (spec.reps > 1) "rep ${next.rep}" else null
                StepKind.recovery -> {
                    val len = when (next.target) {
                        TargetKind.time -> gap(next.value.toLong())
                        TargetKind.distance -> metres(next.value.toDouble())
                        TargetKind.equalToPreviousWork -> spec.steps.getOrNull(i - 1)?.let { w ->
                            if (w.target == TargetKind.distance) metres(w.value.toDouble()) else gap(w.value.toLong())
                        } ?: return null
                    }
                    "$len ${if (next.style == RecoveryStyle.stand) "stand" else next.style.name}"
                }
            }
        }
    }

    /** Cooper (1968): VO2max ≈ (d − 504.9) / 44.73, d in metres over 12 minutes. */
    fun cooperVo2(metres: Double): Double = CooperProjection.vo2(metres)

    private fun metres(m: Double): String =
        if (m >= 1_000 && m % 1_000 == 0.0) "${(m / 1_000).toInt()} kilometres" else "${m.toInt()} metres"

    /**
     * A spoken gap in whole seconds (#79 review): under a minute "1 second" / "17 seconds", from
     * a minute on in minutes and seconds, "1 minute", "2 minutes 17", never "137 seconds".
     * Pinned with the engine by `fixtures/phase4/spoken_gaps.json`.
     */
    fun gap(seconds: Long): String {
        val s = abs(seconds)
        if (s < 60) return if (s == 1L) "1 second" else "$s seconds"
        val m = s / 60
        val rest = s % 60
        val mins = if (m == 1L) "1 minute" else "$m minutes"
        return if (rest == 0L) mins else "$mins $rest"
    }

    /** The recorder's `lastRep` rule: the last work step of a session with more than one rep. */
    private fun lastRep(spec: SessionSpec, repIndex: Int): Boolean = spec.reps > 1 && repIndex == spec.reps

    /** mm:ss (h:mm:ss past an hour) of a duration in ms. */
    fun clock(ms: Double): String {
        val s = (ms / 1_000).roundToLong()
        val h = s / 3_600
        val m = (s % 3_600) / 60
        val sec = s % 60
        return if (h > 0) "$h:${m.toString().padStart(2, '0')}:${sec.toString().padStart(2, '0')}" else "$m:${sec.toString().padStart(2, '0')}"
    }
}
