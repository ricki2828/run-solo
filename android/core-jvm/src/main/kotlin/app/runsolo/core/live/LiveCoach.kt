package app.runsolo.core.live

import app.runsolo.core.journal.JournalLine
import app.runsolo.core.model.CueKind
import app.runsolo.core.model.CueProfile
import app.runsolo.core.model.LiveBoardKind
import app.runsolo.core.model.LiveContext
import app.runsolo.core.model.NudgePlan
import app.runsolo.core.model.Phase
import app.runsolo.core.model.RunMode
import app.runsolo.core.model.SessionSpec
import app.runsolo.core.model.StepKind
import app.runsolo.core.model.TargetKind
import kotlin.math.floor

/**
 * The live "you vs you" for one run (Phase 4 §3.2, LV1): decides when a compare fires and what
 * it says, from the [LiveContext] the engine packed at Start. Pure and JVM-tested; the shell
 * speaks [Fire.text], journals a `cue_fired` line and sends `CompareEvent`.
 *
 * Firing rules:
 *  - only with a cue that already speaks: a Free / Laps km (the km cue is spoken only when it has
 *    a compare, so a run with no context stays as quiet as before), a rep end in intervals (the
 *    recovery's start cue, or the cool-down cue after the last rep), a Cooper minute (rank at 3,
 *    6 and 9 only), a km of a distance step with a target (parkrun);
 *  - never on a `short` profile rep except after the final rep; one compare per cue;
 *  - each (board, point) fires once: journaled `cue_fired` lines are done after a restore, and a
 *    point that passed while the process was dead is dropped, never spoken late ([resumeAt]).
 * Free / Laps race the 5K board for km 1–5 and the 10K board for km 6–10; nothing after 10 km.
 */
class LiveCoach(
    private val context: LiveContext?,
    private val mode: RunMode,
    private val spec: SessionSpec?,
    fired: Collection<JournalLine.CueFired> = emptyList(),
) {
    /** "Mute tips" for this run: compares still fire (overlay, journal) but are not spoken. */
    var muted: Boolean = context?.coachingMuted ?: false

    /** One compare. [text] is what to append to the cue; [overlay] is false when a recovery is under 20 s (voice only). */
    data class Fire(val result: CompareResult, val text: String, val overlay: Boolean = true, val speak: Boolean = true) {
        val key: String get() = result.boardKey
        val index: Int get() = result.index
    }

    private val done = HashSet<String>().apply {
        for (f in fired) if (f.kind == JournalLine.FiredKind.compare) add(doneKey(f.key, f.index))
    }
    private val livePaces = ArrayList<Double?>()
    private var lastKm = 0

    /** Active run ms at the last whole km (null after a restore until the next km), for the split pace. */
    private var lastKmActiveMs: Long? = 0

    /** Settings → Voice → "Km splits" (default on): Free runs say each km. */
    var kmSplits: Boolean = true

    /** A whole km of a Free or Laps run: the split to say ([base], Free only) and its compare, if any. */
    data class KmCue(val km: Int, val base: String?, val fire: Fire?)

    /**
     * An intervals run with a board to race: a rep ended by a manual lap holds its following cue
     * until the lap's interpolated distance is known ([app.runsolo.core.record.LapDispatch]), up to
     * a second; every other run speaks its cues at once.
     */
    val holdsRepEndCues: Boolean get() = mode == RunMode.intervals && context?.boards?.any { it.kind == LiveBoardKind.intervals } == true

    /** Anything to compare at all (the notification offers "Mute tips" only then). */
    val active: Boolean get() = context != null && (context.boards.isNotEmpty() || context.target != null || !context.cooperHistory.isNullOrEmpty())

    /** Live untrimmed rep paces so far (s/km, null = unclean), for the rep-end compare. */
    val repPaces: List<Double?> get() = livePaces

    /** After a restore: every km already passed is done, so none is spoken late. */
    fun resumeAt(distanceM: Double) {
        lastKm = maxOf(lastKm, floor(distanceM / 1_000).toInt())
        lastKmActiveMs = null // the next km's split pace spans the dark gap: not said
    }

    /**
     * A lap was published (live distance and active time of the lap itself). A lap that ended a
     * work step adds that rep's live untrimmed pace (lap distance ÷ lap time), null when there is
     * no distance to speak of.
     */
    fun lapEnded(lapIndex: Int, distanceM: Double, activeMs: Long) {
        val s = spec ?: return
        if (s.steps.isEmpty()) return
        val step = s.steps.getOrNull(lapIndex - 1) ?: return // lap 0 is the warm-up
        if (step.kind != StepKind.work) return
        livePaces.add(if (distanceM >= 1.0 && activeMs > 0) activeMs / 1_000.0 / (distanceM / 1_000) else null)
    }

    /**
     * Free / Laps: the tick moved the distance from [prevD] at [prevT] to [d] at [t]; a whole km
     * crossed here (at its interpolated time; [activeAt] maps a time to active run ms). A Free run
     * says the split ("3 k, 15 minutes 20, pace 5:07.") with the rank appended when a board has
     * one; a Laps run says nothing at a km (it has no km cue), so its compare is overlay only.
     * Two kms in one tick (a catch-up) give only the last. Compares stop after 10 km.
     */
    fun onTick(prevT: Long, prevD: Double, t: Long, d: Double, activeAt: (Long) -> Long): KmCue? {
        if (spec?.steps?.isNotEmpty() == true || (mode != RunMode.free && mode != RunMode.laps)) return null
        val km = floor(d / 1_000).toInt()
        if (km <= lastKm || d <= prevD) return null
        val skipped = km > lastKm + 1
        lastKm = km
        val mark = km * 1_000.0
        val tk = if (prevD >= mark) prevT else prevT + ((mark - prevD) / (d - prevD) * (t - prevT)).toLong()
        val active = activeAt(tk)
        val splitMs = lastKmActiveMs?.takeIf { !skipped }?.let { active - it }
        lastKmActiveMs = active
        val base = if (mode == RunMode.free && kmSplits) LiveWords.kmSplit(km, active, splitMs) else null
        return KmCue(km, base, compareAtKm(km, active)).takeIf { it.base != null || it.fire != null }
    }

    private fun compareAtKm(km: Int, active: Long): Fire? {
        if (context == null || km > 10) return null
        val boardM = if (km <= 5) 5_000.0 else 10_000.0
        val board = context.boards.firstOrNull { it.kind == LiveBoardKind.distance && it.targetM == boardM } ?: return null
        val r = LiveCompare.distance(board, km, active) ?: return null
        if (!claim(r)) return null
        return Fire(r, LiveWords.compare(r), speak = !muted && mode == RunMode.free && kmSplits)
    }

    /**
     * A cue the core emitted ([kind], [index] = its minute or km, [value] = its projection), with
     * the core already past it ([phase], [stepIndex] = what comes next). [stepElapsedMs] = active
     * ms into the current step; [nextDurationMs] = the length of a timed step starting now.
     */
    fun atCue(kind: CueKind, index: Int?, value: Double?, phase: Phase, stepIndex: Int?, stepElapsedMs: Long, nextDurationMs: Long?): Fire? {
        context ?: return null
        val s = spec ?: return null
        // Rep end: the recovery's start, or the cool-down cue after the last rep.
        val repEnd = (kind == CueKind.start && phase == Phase.recovery) || (kind == CueKind.phaseEnd && phase == Phase.cooldown && s.steps.isNotEmpty())
        if (repEnd && mode == RunMode.intervals) {
            val rep = livePaces.size
            val last = rep == s.reps
            if (s.cueProfile == CueProfile.short && !last) return null
            val board = context.boards.firstOrNull { it.kind == LiveBoardKind.intervals } ?: return null
            val r = LiveCompare.intervals(board, livePaces, rep) ?: return null
            if (!claim(r)) return null
            val recoveryStep = stepIndex?.let { s.steps.getOrNull(it) }
            val shortRecovery = !last && recoveryStep?.target != TargetKind.distance && (nextDurationMs ?: Long.MAX_VALUE) < SHORT_RECOVERY_MS
            return Fire(r, LiveWords.compare(r), overlay = !shortRecovery, speak = !muted)
        }
        if (kind != CueKind.projection || index == null || value == null) return null
        if (s.cueProfile == CueProfile.cooper) {
            if (index !in COOPER_RANK_MINUTES) return null
            val r = LiveCompare.cooper(context.cooperHistory.orEmpty(), index, CooperProjection.vo2(value)) ?: return null
            if (!claim(r)) return null
            return Fire(r, LiveWords.compare(r), speak = !muted)
        }
        // A km of a distance step (parkrun): against the target's even split.
        val target = context.target ?: return null
        val r = LiveCompare.target(target, index, stepElapsedMs) ?: return null
        if (!claim(r)) return null
        return Fire(r, LiveWords.compare(r), speak = !muted)
    }

    private fun claim(r: CompareResult): Boolean = done.add(doneKey(r.boardKey, r.index))

    private fun doneKey(key: String, index: Int) = "$key#$index"

    companion object {
        /** A recovery shorter than this gets the compare in voice only, no overlay card (§3.2). */
        const val SHORT_RECOVERY_MS = 20_000L

        /** Cooper ranks against past tests only at these minutes (the projection speaks every minute). */
        val COOPER_RANK_MINUTES = setOf(3, 6, 9)
    }
}

/**
 * In-run nudges (Phase 4 §3.5, B5). LC1 ships the [NudgePlan] as an empty stub (WARN-6), so there
 * is no rule to evaluate yet: CR1 fills the plan and this evaluator. The cue path already carries
 * a nudge as the lowest-priority part ([CueComposer]).
 */
object NudgeEvaluator {
    @Suppress("UNUSED_PARAMETER")
    fun evaluate(plan: NudgePlan?, kind: CueKind, index: Int?): String? = null
}
