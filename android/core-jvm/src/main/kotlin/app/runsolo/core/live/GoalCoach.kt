package app.runsolo.core.live

import app.runsolo.core.model.CueKind
import app.runsolo.core.model.LiveBoardKind
import app.runsolo.core.model.LiveContext
import app.runsolo.core.model.Phase
import app.runsolo.core.model.SessionSpec
import app.runsolo.core.model.Step
import app.runsolo.core.model.TargetKind
import app.runsolo.core.record.CueWords
import app.runsolo.core.record.RecorderCore
import java.util.Locale

/**
 * GOAL runs (§G, G2): the goal-reached moment. When the goal's one step closes (its distance or
 * its time from Start, pauses out) the core emits the step's `phaseEnd` and moves to an open
 * cool-down; this turns that into one voice line ("10K done, 49:12, new best." / "30 minutes
 * done, 6.21 km.") plus a buzz and the app's goal card. Said once: a restore past the goal knows
 * it was reached (the core replays the step end), and a kill before the goal marks the result
 * interrupted (WARN-G2: goal time with no distance behind it), which also drops "new best".
 * The engine's `GoalResult` from the run file is the result of record; this is the live moment.
 */
class GoalCoach(private val spec: SessionSpec?, private val context: LiveContext?) {
    data class Reached(
        /** True for a distance goal, false for a time goal. */
        val distanceGoal: Boolean,
        /** The goal: metres or seconds. */
        val goalValue: Int,
        /** Moving time at the goal point (ms, pauses and gaps out). */
        val timeMs: Long,
        val distanceM: Double,
        val newBest: Boolean,
        val interrupted: Boolean,
        val text: String,
    )

    private var announced = false

    /** A kill gap fell before the goal (WARN-G2). */
    var interrupted = false
        private set

    /** After a restore: [reachedBeforeKill] = the journal already holds the goal's end; otherwise the gap falls before the goal. */
    fun restored(reachedBeforeKill: Boolean) {
        if (reachedBeforeKill) announced = true else interrupted = true
    }

    /** A cue the core emitted, with the core already past it; [end] = [RecorderCore.finalStepEnd]. */
    fun atCue(kind: CueKind, phase: Phase, end: RecorderCore.StepEnd?): Reached? {
        val s = spec ?: return null
        if (!s.isGoal || announced || kind != CueKind.phaseEnd || phase != Phase.cooldown || end == null) return null
        announced = true
        val step = s.steps.first()
        val distanceGoal = step.target == TargetKind.distance
        val newBest = !interrupted && (if (distanceGoal) beatsDistanceBoard(step, end.activeMs) else beatsTimeBoard(step, end.distanceM))
        val best = if (newBest) ", new best" else ""
        val text = if (distanceGoal) {
            "${s.name} done, ${CueWords.clock(end.activeMs.toDouble())}$best."
        } else {
            "${s.name} done, ${String.format(Locale.US, "%.2f", end.distanceM / 1_000)} km$best."
        }
        return Reached(distanceGoal, step.value, end.activeMs, end.distanceM, newBest, interrupted, text)
    }

    /** The goal's distance board by key (finalMetric = ms, lower is better): a new best beats every entry. */
    private fun beatsDistanceBoard(step: Step, timeMs: Long): Boolean {
        val board = boardOf(step, LiveBoardKind.distance) ?: return false
        return board.entries.isNotEmpty() && board.entries.all { timeMs < it.finalMetric }
    }

    /** The goal's distance-in-time board by key (finalMetric = metres, higher is better). */
    private fun beatsTimeBoard(step: Step, distanceM: Double): Boolean {
        val board = boardOf(step, LiveBoardKind.distanceInTime) ?: return false
        return board.entries.isNotEmpty() && board.entries.all { distanceM > it.finalMetric }
    }

    // By key, never targetM: the Half's board is 21 097.5 m, its step 21 098 m (#68 review P2).
    private fun boardOf(step: Step, kind: LiveBoardKind) =
        context?.boards?.firstOrNull { it.kind == kind && it.key == boardKey(step) }

    companion object {
        /**
         * The board a goal step ranks on; mirrors the engine's `GoalCatalogue.boardKeyOf`
         * (pinned by the shared `fixtures/phase4/goal_live_context.json`): a standard distance its
         * best-effort board, a standard time its distance-in-time board, else `goal:d<exact metres>`
         * (the app takes them to 0.1 of the runner's unit: 7.5 mi is d12070) or `goal:t<seconds>`.
         */
        fun boardKey(step: Step): String = when (step.target) {
            TargetKind.time -> when (step.value) {
                1_800 -> "be:t1800"
                3_600 -> "be:t3600"
                else -> "goal:t${step.value}"
            }
            else -> when (step.value) {
                5_000 -> "be:5000"
                10_000 -> "be:10000"
                21_098 -> "be:21097"
                42_195 -> "be:42195"
                else -> "goal:d${step.value}"
            }
        }
    }
}
