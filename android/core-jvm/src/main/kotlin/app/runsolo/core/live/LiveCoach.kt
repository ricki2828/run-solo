package app.runsolo.core.live

import app.runsolo.core.journal.JournalLine
import app.runsolo.core.journal.RunEvent
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
import app.runsolo.core.record.RecorderCore
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

    /**
     * One compare. [text] is what to append to the cue; [overlay] is false when a recovery is under
     * 20 s (voice only); [base], when spoken, replaces the cue's own words (a goal km says "3 k."
     * instead of "On pace for 1:28:00").
     */
    data class Fire(val result: CompareResult, val text: String, val overlay: Boolean = true, val speak: Boolean = true, val base: String? = null) {
        val key: String get() = result.boardKey
        val index: Int get() = result.index
    }

    private val done = HashSet<String>().apply {
        for (f in fired) if (f.kind == JournalLine.FiredKind.compare) add(doneKey(f.key, f.index))
    }
    private val livePaces = ArrayList<Double?>()
    private var lastKm = 0

    /** "Best start to this session you've had" is said once a run (#79 review), not after every rep it holds. */
    private var bestStartSaid = false

    /** Active run ms at the last whole km (null after a restore until the next km), for the split pace. */
    private var lastKmActiveMs: Long? = 0

    /** Settings → Voice → "Km splits" (default on): Free runs say each km. */
    var kmSplits: Boolean = true

    /** A GOAL run past its goal (§G): the open cool-down says km splits and nothing else. */
    var goalReached: Boolean = false
        private set

    /** The goal was reached at [distanceM] / [activeMs] (or, after a restore, is already behind): km splits count on from there. */
    fun goalReachedAt(distanceM: Double, activeMs: Long?) {
        goalReached = true
        lastKm = maxOf(lastKm, floor(distanceM / 1_000).toInt())
        lastKmActiveMs = activeMs
    }

    /** A whole km of a Free or Laps run: the split to say ([base], Free only) and its compare, if any. */
    data class KmCue(val km: Int, val base: String?, val fire: Fire?, val nudge: Nudge? = null)

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
        kmHr.clean = false // and its HR was not seen whole
    }

    /** A session with no warm-up begins step 1 at Start, from 0 m; otherwise the warm-up lap starts it. */
    private var stepStartD: Double? = if (spec?.warmupSeconds == 0) 0.0 else null
    private var stepStartActiveMs = 0L
    private var stepHadGap = false

    /**
     * A lap was published: [step] = what it did to the steps ([RecorderCore.lapStep]),
     * [totalDistanceM] / [activeMs] = the run's cumulative live distance and active time at it.
     * A lap that ended a work step adds that rep's live untrimmed pace: the step's distance over
     * its active time, from the lap that started the step, so a 0 s recovery (no lap) or a
     * volume-key lap mid-rep (ends nothing) never shifts the reps (#48 review P1). A rep that
     * spanned a kill gap is null, unclean, as I3 and LB2 treat it; so is one with no distance.
     */
    fun lapEnded(step: RecorderCore.LapStep?, totalDistanceM: Double, activeMs: Long) {
        val s = spec ?: return
        if (s.steps.isEmpty() || step == null) return
        val ended = step.endedStep?.let { s.steps.getOrNull(it) }
        if (ended?.kind == StepKind.work) {
            val d0 = stepStartD
            val d = d0?.let { totalDistanceM - it } ?: 0.0
            val ms = activeMs - stepStartActiveMs
            livePaces.add(if (d0 == null || stepHadGap || d < 1.0 || ms <= 0) null else ms / 1_000.0 / (d / 1_000))
        }
        if (step.startsStep) {
            stepStartD = totalDistanceM
            stepStartActiveMs = activeMs
            stepHadGap = false
        }
    }

    /** A kill gap (the process was dead) inside the current step: its rep, if it is one, is unclean. */
    fun gap() {
        stepHadGap = true
    }

    /**
     * After a restore: the reps before the kill, in journal order, each by the step its lap ended
     * ([core] replayed the laps, so [RecorderCore.lapStep] holds them); a gap marks the step it
     * falls in unclean, the resume's own gap (journaled first) included. [lapTotals] = the run's
     * cumulative (distance m, active ms) at each journaled lap.
     */
    fun restoreReps(events: List<RunEvent>, core: RecorderCore, lapTotals: List<Pair<Double, Long>>) {
        var i = 0
        for (e in events) {
            when (e) {
                is RunEvent.Gap -> gap()
                is RunEvent.Lap -> {
                    lapTotals.getOrNull(i)?.let { (d, a) -> lapEnded(core.lapStep(i), d, a) }
                    i++
                }
                else -> Unit
            }
        }
    }

    /**
     * Free / Laps: the tick moved the distance from [prevD] at [prevT] to [d] at [t]; a whole km
     * crossed here (at its interpolated time; [activeAt] maps a time to active run ms). A Free run
     * says the split ("3 k, 15 minutes 20, pace 5:07.") with the rank appended when a board has
     * one; a Laps run says nothing at a km (it has no km cue), so its compare is overlay only.
     * Two kms in one tick (a catch-up) give only the last. Compares stop after 10 km.
     */
    fun onTick(prevT: Long, prevD: Double, t: Long, d: Double, hr: Int? = null, activeAt: (Long) -> Long): KmCue? {
        val goalCooldown = goalReached && spec?.isGoal == true
        if (!goalCooldown && (spec?.steps?.isNotEmpty() == true || (mode != RunMode.free && mode != RunMode.laps))) return null
        val km = floor(d / 1_000).toInt()
        if (km <= lastKm || d <= prevD) {
            kmHr.add(hr)
            return null
        }
        val skipped = km > lastKm + 1
        lastKm = km
        val mark = km * 1_000.0
        val tk = if (prevD >= mark) prevT else prevT + ((mark - prevD) / (d - prevD) * (t - prevT)).toLong()
        val active = activeAt(tk)
        val splitMs = lastKmActiveMs?.takeIf { !skipped }?.let { active - it }
        lastKmActiveMs = active
        // This tick's sample is at or after the crossing: it opens the next km's HR.
        val hrMean = kmHr.close(clean = !skipped)
        kmHr.add(hr)
        // A goal's open cool-down says km splits only: no compare, no nudge.
        val base = if ((mode == RunMode.free || goalCooldown) && kmSplits) LiveWords.kmSplit(km, active, splitMs) else null
        val nudge = if (mode == RunMode.free && kmSplits) kmNudge(km, active, splitMs, hrMean) else null
        val fire = if (goalCooldown) null else compareAtKm(km, active)
        return KmCue(km, base, fire, nudge).takeIf { it.base != null || it.fire != null }
    }

    // ---- nudges (CR1): the engine's thresholds against live figures ----

    /**
     * A nudge, said as its own line after the cue it belongs to ([NudgeFollowUp]); [rule] and
     * [index] key its `cue_fired` line. Offered, not claimed: it is done only once [nudgeSaid].
     */
    data class Nudge(val rule: String, val index: Int, val text: String)

    /**
     * [n] was actually spoken (and journaled): its rule is done for this run, restore included.
     * Each rule speaks at most once per run (founder 26-Sep: HR drift at every km, rep fade after
     * every rep, was nagging).
     */
    fun nudgeSaid(n: Nudge) {
        saidRules.add(n.rule)
    }

    private fun nudgeKey(rule: String, index: Int) = "$rule:$index"

    /** Rules already spoken this run (the journal's `cf` nudge lines after a restore). */
    private val saidRules = HashSet<String>().apply {
        for (f in fired) if (f.kind == JournalLine.FiredKind.nudge) add(f.key)
    }

    /**
     * Live HR over the current km, the engine's kmHr rule (#56): the plain mean of the HR-bearing
     * samples with t in [start of the km, its end), km 1 from Start; null when under half the
     * samples carry HR, or the km was not seen whole (a catch-up tick, a restore).
     */
    private class KmHr {
        private var sum = 0.0
        private var withHr = 0
        private var samples = 0
        var clean = true

        fun add(hr: Int?) {
            samples++
            if (hr != null && hr > 0) {
                withHr++
                sum += hr
            }
        }

        fun close(clean: Boolean): Double? {
            val mean = if (this.clean && clean && samples > 0 && withHr * 2 >= samples) sum / withHr else null
            sum = 0.0
            withHr = 0
            samples = 0
            this.clean = true
            return mean
        }
    }

    private val kmHr = KmHr()

    /** At a Free run's km: a fast first km (km 1), else HR up for the pace (km ≥ firstKm). One per km. */
    private fun kmNudge(km: Int, activeAtKm: Long, splitMs: Long?, hrMean: Double?): Nudge? {
        if (muted) return null
        val plan = context?.nudges ?: return null
        if (km == 1) plan.fastStart?.let { r -> if (activeAtKm < r.km1MaxMs) return claimNudge(NudgePlan.FAST_START, 1, r.text) }
        val r = plan.hrDrift ?: return null
        if (splitMs == null || hrMean == null || !r.firesAt(km, splitMs / 1_000.0, hrMean)) return null
        return claimNudge(NudgePlan.HR_DRIFT, km, r.text)
    }

    /**
     * At a rep end (the cue [atCue] would compare on): rep r ≥ 3 slower than rep 1 by more than
     * the plan's limit for r. Never on a short-profile rep before the last, never in a Cooper.
     */
    fun nudgeAtCue(kind: CueKind, phase: Phase): Nudge? {
        if (muted || mode != RunMode.intervals) return null
        val s = spec ?: return null
        if (s.isGoal) return null
        if (!isRepEnd(kind, phase, s)) return null
        val rep = livePaces.size
        if (!repFadeDue(s, rep)) return null
        return claimNudge(NudgePlan.REP_FADE, rep, context!!.nudges!!.repFade!!.text)
    }

    /** The rep-fade nudge would fire at the end of [rep] (and has not spoken this run). */
    private fun repFadeDue(s: SessionSpec, rep: Int): Boolean {
        if (muted || rep < 3 || (s.cueProfile == CueProfile.short && rep != s.reps)) return false
        val rule = context?.nudges?.repFade ?: return false
        val limit = rule.maxDropSecPerKm.getOrNull(rep - 1) ?: return false
        val first = livePaces[0] ?: return false
        val now = livePaces[rep - 1] ?: return false
        return now - first > limit && claimNudge(NudgePlan.REP_FADE, rep, rule.text) != null
    }

    private fun isRepEnd(kind: CueKind, phase: Phase, s: SessionSpec) =
        (kind == CueKind.start && phase == Phase.recovery) || (kind == CueKind.phaseEnd && phase == Phase.cooldown && s.steps.isNotEmpty())

    /** A nudge whose rule has not spoken this run, not blocked by the last run (a dropped one stays unsaid). */
    private fun claimNudge(rule: String, index: Int, text: String): Nudge? {
        if (rule in saidRules || context?.nudges?.blocked?.contains(nudgeKey(rule, index)) == true) return null
        return Nudge(rule, index, text)
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
        // A GOAL run (§G) is one step, not reps: its end is the goal line (GoalCoach); a km of a
        // distance goal races the goal's own board at that split, as a Free run's km races the 5K.
        if (s.isGoal) return goalKm(kind, index, s, stepElapsedMs)
        // Rep end: the recovery's start, or the cool-down cue after the last rep.
        val repEnd = isRepEnd(kind, phase, s)
        if (repEnd && mode == RunMode.intervals) {
            val rep = livePaces.size
            val last = rep == s.reps
            if (s.cueProfile == CueProfile.short && !last) return null
            val board = context.boards.firstOrNull { it.kind == LiveBoardKind.intervals } ?: return null
            val r = LiveCompare.intervals(board, livePaces, rep) ?: return null
            if (!claim(r)) return null
            val recoveryStep = stepIndex?.let { s.steps.getOrNull(it) }
            val shortRecovery = !last && recoveryStep?.target != TargetKind.distance && (nextDurationMs ?: Long.MAX_VALUE) < SHORT_RECOVERY_MS
            // "Best start to this session" (#79 review): said once, and never on the rep a fade
            // nudge fires (the two contradict). The overlay still shows the rank.
            val bestLine = r.of > 2 && r.rank == 1
            val quiet = bestLine && (bestStartSaid || repFadeDue(s, rep))
            if (bestLine && !quiet && !muted) bestStartSaid = true
            return Fire(r, LiveWords.compare(r), overlay = !shortRecovery, speak = !muted && !quiet)
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

    /**
     * A whole km of a distance goal ([index] = the km, [activeMs] = active ms from Start: a goal
     * has no warm-up) against the goal's board, by key ([GoalCoach.boardKey]): "3 k. Number 2 of
     * 7, 12 seconds off your best." Entries without a split at this km sit it out. No board, no
     * split, or muted: the cue keeps its own "On pace for …".
     */
    private fun goalKm(kind: CueKind, index: Int?, s: SessionSpec, activeMs: Long): Fire? {
        if (kind != CueKind.projection || index == null || goalReached) return null
        val step = s.steps.firstOrNull()?.takeIf { it.target == TargetKind.distance } ?: return null
        val key = GoalCoach.boardKey(step)
        val board = context?.boards?.firstOrNull { it.kind == LiveBoardKind.distance && it.key == key } ?: return null
        val r = LiveCompare.distance(board, index, activeMs) ?: return null
        if (!claim(r)) return null
        return Fire(r, LiveWords.compare(r), speak = !muted, base = LiveWords.goalKm(index))
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
