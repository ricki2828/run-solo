package app.runsolo.core.live

import app.runsolo.core.journal.JournalLine
import app.runsolo.core.record.CueWords
import kotlin.math.abs
import kotlin.math.roundToInt
import kotlin.math.roundToLong

/**
 * Mid-run two-button coach prompts (founder 22-Oct, decisions final): at a real fork the voice asks a short question
 * with two answers, on screen as two big buttons and on the headset as one or two presses. Rules decide everything:
 * no LLM, no server. Everything here is pure and driven by explicit times, so it is fully testable in core-jvm.
 *
 * Triggers (at most one per km mark or rep end; priority top to bottom):
 *  - [PromptKind.last2k]: a distance goal, the first km mark with 2.5 km or less to go (push or hold);
 *  - [PromptKind.behindTarget]: a chase-mode distance goal with a target, behind it by [BEHIND_MS] or more AND still
 *    falling back (the gap grew by [GROWING_MS] over the last km), once a run, and never against the PB pace on a
 *    Free run (that is not a race) or in Steady (no comparisons) (push or ease off);
 *  - [PromptKind.aheadOfPb]: chase mode, ahead of the PB window by [AHEAD_MS] or more (push or hold);
 *  - [PromptKind.betweenReps]: an interval session, at a rep end that is not the last (push or hold).
 *
 * Limits: at most [MAX_PROMPTS] a run, at least [MIN_GAP_MS] of run time and (on distance runs) [MIN_GAP_M] between two,
 * never in the first km, never while one is open. On a distance goal the last slot is kept for the last 2 km. The
 * [TIMEOUT_MS] window starts when the question has been said (the caller starts it), is frozen while the run is
 * paused, and a real input always beats it; no answer holds the current target.
 */
enum class PromptKind(val key: String) {
    last2k("last2k"),
    behindTarget("behindTarget"),
    aheadOfPb("aheadOfPb"),
    betweenReps("betweenReps"),
}

/** What the runner picks. [ease] exists only on [PromptKind.behindTarget]; [hold] is always the safe default. */
enum class PromptChoice(val key: String, val label: String) {
    push("push", "Push"),
    hold("hold", "Hold"),
    ease("ease", "Ease off"),
    ;

    companion object {
        fun parse(key: String?): PromptChoice? = entries.firstOrNull { it.key == key }
    }
}

/** Where an answer came from. [timeout] = nobody answered, the target was held. */
enum class PromptSource(val key: String) {
    tap("tap"),
    headset("headset"),
    timeout("timeout"),
    ;

    companion object {
        fun parse(key: String?): PromptSource? = entries.firstOrNull { it.key == key }
    }
}

/**
 * An open prompt. [text] is what the voice says (it ends in the question), [options] are the two buttons (first =
 * single headset press, second = double press), [km] the whole km mark (or the rep) it fell on, [openedAtMs] run time.
 */
data class Prompt(
    val id: Int,
    val kind: PromptKind,
    val km: Int,
    val options: List<PromptChoice>,
    val text: String,
    val openedAtMs: Long,
    val timeoutMs: Long = CoachPrompter.TIMEOUT_MS,
)

/** One resolved prompt, for the run record (and the later post-run line). */
data class PromptAnswer(
    val prompt: Prompt,
    val choice: PromptChoice,
    val source: PromptSource,
    /** Run time of the answer or the timeout. */
    val atMs: Long,
    /** Run time the answer window started (the question had been said); [Prompt.openedAtMs] when it never started. */
    val windowStartMs: Long = prompt.openedAtMs,
    /** Closed without a word: the runner stopped the run (a long manual pause), so "No answer. Holding." would be noise. */
    val quiet: Boolean = false,
) {
    /** The spoken acknowledgement; null for a [quiet] close. */
    val spoken: String?
        get() = when {
            quiet -> null
            source == PromptSource.timeout -> "No answer. Holding."
            choice == PromptChoice.push -> "Pushing."
            choice == PromptChoice.ease -> "Easing off."
            else -> "Holding."
        }
}

/**
 * What a choice does to the rest of the run: a factor on the target pace (below 1 = tighter) and on the gap between
 * the coach's pace checks (below 1 = more cues). Hold changes nothing; a later push or ease replaces an earlier one.
 */
data class PromptEffect(
    val paceFactor: Double = 1.0,
    val everyFactor: Double = 1.0,
    /** Ease off: the coach stops saying "Pick it up" (the runner said they are easing); "Ease off, fast" still speaks. */
    val quietSlow: Boolean = false,
    /** Between reps: only the next rep (the question said "the next one"). */
    val oneRep: Boolean = false,
) {
    /** The target pace (s/km) for the rest of the run; null stays null (no target to tighten). */
    fun targetPace(base: Double?): Double? = base?.times(paceFactor)

    /** The effect after [choice] to a [kind] question: hold keeps this one; a between-reps answer lasts one rep. */
    fun after(choice: PromptChoice, kind: PromptKind? = null): PromptEffect = when (choice) {
        PromptChoice.push -> PUSH.copy(oneRep = kind == PromptKind.betweenReps)
        PromptChoice.ease -> EASE.copy(oneRep = kind == PromptKind.betweenReps)
        PromptChoice.hold -> this
    }

    companion object {
        val NONE = PromptEffect()

        /** 3 % faster than the target, a pace check every 30 s instead of 60. */
        val PUSH = PromptEffect(paceFactor = 0.97, everyFactor = 0.5)

        /** 4 % looser, a check every 90 s: calmer. */
        val EASE = PromptEffect(paceFactor = 1.04, everyFactor = 1.5, quietSlow = true)
    }
}

/**
 * Which headset key means which answer while a prompt is open. Plain pause/play/hook presses are counted (one = first
 * option, two quick = second, [HeadsetPresses]); MEDIA_NEXT, which most Bluetooth earbuds send for a double tap, is the
 * second option at once and MEDIA_PREVIOUS the first. Anything else is not ours. Key codes are Android's `KeyEvent`.
 */
object HeadsetKeys {
    const val HEADSETHOOK = 79
    const val MEDIA_PLAY_PAUSE = 85
    const val MEDIA_NEXT = 87
    const val MEDIA_PREVIOUS = 88
    const val MEDIA_PLAY = 126
    const val MEDIA_PAUSE = 127

    /** What a key does: [COUNT] a counted press, 0 or 1 an option picked outright, null = not a prompt key. */
    fun answerFor(keyCode: Int): Int? = when (keyCode) {
        HEADSETHOOK, MEDIA_PLAY_PAUSE, MEDIA_PLAY, MEDIA_PAUSE -> COUNT
        MEDIA_NEXT -> 1
        MEDIA_PREVIOUS -> 0
        else -> null
    }

    /** A press to be counted (single or double), not an option picked outright. */
    const val COUNT = -1
}

/**
 * Headphone presses while a prompt is open: one press = the first option, two quick presses = the second. A press
 * is final only once [DOUBLE_MS] passes with no second; [poll] says so. Pure: times are passed in.
 */
class HeadsetPresses {
    private var firstAt: Long? = null

    /** A press at [nowMs]; returns 1 (second option) at once for the second of two quick presses, else null. */
    fun press(nowMs: Long): Int? {
        val first = firstAt
        if (first != null && nowMs - first <= DOUBLE_MS) {
            firstAt = null
            return 1
        }
        firstAt = nowMs
        return null
    }

    /** At [nowMs]: 0 (first option) when one press has waited out [DOUBLE_MS] alone, else null. */
    fun poll(nowMs: Long): Int? {
        val first = firstAt ?: return null
        if (nowMs - first < DOUBLE_MS) return null
        firstAt = null
        return 0
    }

    fun reset() {
        firstAt = null
    }

    /** True while a press waits to learn whether a second comes. */
    val pending: Boolean get() = firstAt != null

    companion object {
        const val DOUBLE_MS = 450L
    }
}

/** What is known at a whole-km mark, for the trigger rules. A null field is unknown and its rule stays quiet. */
data class KmFacts(
    val km: Int,
    /** Live active ms minus the PB window's split at this km (negative = ahead); null = no base or chase off. */
    val gapMs: Long?,
    /** The board's spoken name ("5K"), and whether it is a nearby board's pace ("10K" for an 8 km goal). */
    val label: String?,
    val proxy: Boolean,
    /** A distance goal's metres; null for a Free run. */
    val goalDistanceM: Double?,
    /** Live active ms minus the goal's target even split at this km (positive = behind); null = no target. */
    val behindTargetMs: Long?,
    /** Chase mode: gap prompts need the PB comparison; Steady has no comparisons. */
    val chase: Boolean,
    /** A distance goal's target time (ms), set only when the target is for the goal's own distance; null = no goal time. */
    val goalTimeMs: Long? = null,
)

/**
 * The decision and the clock of the prompts for one run.
 *
 * [restored] = the journaled prompts of an earlier part of this run (after a kill): they count toward the cap and the
 * spacing, an ease off keeps the falling-behind question quiet, and the last push or ease keeps its effect (a
 * between-reps answer lasted one rep and is gone). A prompt open at the kill is not reopened.
 */
class CoachPrompter(restored: List<PromptAnswer> = emptyList(), private val distanceGate: Boolean = true) {
    private var count = 0
    private var lastOpenedMs: Long? = null
    private var lastOpenedM: Double? = null
    private var nextId = 1
    private var last2kDone = false
    private var easedOff = false
    private var behindAsked = false
    private var repPrompts = 0
    private var prevBehindMs: Long? = null
    private var windowStartMs: Long? = null
    private var windowShiftMs = 0L
    private val presses = HeadsetPresses()
    private var lastPauseTickMs: Long? = null
    private var manualSinceMs: Long? = null
    private var openAtMs = 0L
    private var dropAtMs = 0L
    private var routeHeld = false

    /** A prompt decided at a km or a rep end and not yet asked ([decided], [openTick]); null when none waits. */
    var pending: Prompt? = null
        private set

    /** The prompt on screen, or null. */
    var open: Prompt? = null
        private set

    /** The effect of the choices so far; [PromptEffect.NONE] until a push or an ease. */
    var effect: PromptEffect = PromptEffect.NONE
        private set

    init {
        for (a in restored) {
            count++
            lastOpenedMs = a.prompt.openedAtMs
            if (a.prompt.kind == PromptKind.last2k) last2kDone = true
            if (a.prompt.kind == PromptKind.behindTarget) behindAsked = true
            if (a.prompt.kind == PromptKind.betweenReps) repPrompts++
            effect = if (a.prompt.kind == PromptKind.betweenReps) PromptEffect.NONE else effect.after(a.choice, a.prompt.kind)
            if (a.choice == PromptChoice.ease) easedOff = true
            nextId = maxOf(nextId, a.prompt.id + 1)
        }
    }

    val prompts: Int get() = count

    private fun gapOk(nowMs: Long, distanceM: Double): Boolean {
        if (open != null || count >= MAX_PROMPTS) return false
        if (distanceM < FIRST_KM_M) return false
        val at = lastOpenedMs ?: return true
        if (nowMs - at < MIN_GAP_MS) return false
        val m = lastOpenedM
        return !(distanceGate && m != null && distanceM - m < MIN_GAP_M)
    }

    /**
     * A whole km of a Free run or a distance goal ([nowMs] = run time, [distanceM] the distance so far). The prompt to
     * open now, or null. The caller says [Prompt.text], shows it, and calls [opened] once it really did.
     */
    fun atKm(f: KmFacts, nowMs: Long, distanceM: Double): Prompt? {
        // The trend reads the last km's gap, whether or not a prompt could open at it.
        val prevBehind = prevBehindMs
        prevBehindMs = f.behindTargetMs
        if (!gapOk(nowMs, distanceM)) return null
        val phrase = gapPhrase(f)
        val toGo = f.goalDistanceM?.let { goal -> toGoText(goal, f.km) }
        // A goal with a target time names it: where he stands against that clock and what each button means.
        val goalTime = f.goalTimeMs?.takeIf { f.chase && f.behindTargetMs != null }
        if (toGo != null && !last2kDone && goalTime != null) {
            val ahead = -f.behindTargetMs!!
            val where = GoalMargin.phrase(ahead, prevBehind?.let { ahead + it }, goalTime).replaceFirstChar { it.lowercase() }
            val t = CueWords.clock(goalTime.toDouble())
            return make(PromptKind.last2k, f.km, listOf(PromptChoice.push, PromptChoice.hold), "$toGo to go, $where. Push for under $t, or hold this pace?", nowMs)
        }
        if (toGo != null && !last2kDone) {
            val lead = if (phrase != null) "$toGo to go, $phrase" else "$toGo to go."
            return make(PromptKind.last2k, f.km, listOf(PromptChoice.push, PromptChoice.hold), "$lead Push or hold?", nowMs)
        }
        // The last slot of a distance goal is the last 2 km's.
        if (f.goalDistanceM != null && !last2kDone && count >= MAX_PROMPTS - 1) return null
        // Falling behind: a chase goal with a target, behind and still losing ground, once. Never against the PB pace
        // on a Free run (not a race), never in Steady (no comparisons), never after an ease off.
        val behind = f.behindTargetMs
        if (f.chase && !behindAsked && !easedOff && behind != null && prevBehind != null &&
            behind >= BEHIND_MS && behind - prevBehind >= GROWING_MS
        ) {
            if (goalTime != null) {
                val where = GoalMargin.phrase(-behind, -(behind - prevBehind), goalTime)
                return make(PromptKind.behindTarget, f.km, listOf(PromptChoice.push, PromptChoice.ease), "$where. Push to get back on it, or ease off?", nowMs)
            }
            val s = behind / 1_000
            return make(PromptKind.behindTarget, f.km, listOf(PromptChoice.push, PromptChoice.ease), "${CueWords.gap(s)} behind the target. Push or ease off?", nowMs)
        }
        val gap = f.gapMs
        if (f.chase && gap != null && gap <= -AHEAD_MS) {
            return make(PromptKind.aheadOfPb, f.km, listOf(PromptChoice.push, PromptChoice.hold), "${phrase ?: ""} Push or hold?".trim(), nowMs)
        }
        return null
    }

    /** A rep ended in an interval session: [rep] of [reps]. Never after the last rep. */
    fun atRepEnd(rep: Int, reps: Int, nowMs: Long, distanceM: Double): Prompt? {
        // Not after the first rep (nothing to compare yet) and at most twice: a 4x4 does not spend every prompt on its reps.
        if (rep < 2 || rep >= reps || repPrompts >= MAX_REP_PROMPTS || !gapOk(nowMs, distanceM)) return null
        return make(PromptKind.betweenReps, rep, listOf(PromptChoice.push, PromptChoice.hold), "Rep $rep done. Push the next one or hold?", nowMs)
    }

    private fun make(kind: PromptKind, km: Int, options: List<PromptChoice>, text: String, nowMs: Long) =
        Prompt(nextId, kind, km, options, text, nowMs)

    /** [p] was decided at run time [nowMs]: it waits [OPEN_DELAY_MS] so the km cue and any moment overlay go first. */
    fun decided(p: Prompt, nowMs: Long) {
        pending = p
        openAtMs = nowMs + OPEN_DELAY_MS
        dropAtMs = openAtMs + ROUTE_MAX_WAIT_MS
        routeHeld = false
    }

    /** What a waiting prompt does this tick ([openTick]). */
    sealed interface PendingStep {
        data object Wait : PendingStep
        data class Open(val prompt: Prompt) : PendingStep
        /** Never asked and never counted: the caller disarms the headset. */
        data object Drop : PendingStep
    }

    /**
     * Once a tick at run time [nowMs], for the [pending] prompt: [speechBusy] = a line is still being said, [routeBusy] =
     * a route cue is on screen or about to be said (off route, turn around, a turn just ahead), [manualPause] = paused by
     * hand. The question never covers a route cue: it waits while one is up, then lets the route's own line be said
     * ([OPEN_DELAY_MS] again), and is dropped if the route keeps it waiting past [ROUTE_MAX_WAIT_MS]. A prompt still
     * waiting when the runner has paused by hand is dropped. Speech is waited out for at most [SPEECH_MAX_WAIT_MS].
     */
    fun openTick(nowMs: Long, speechBusy: Boolean, routeBusy: Boolean, manualPause: Boolean): PendingStep {
        val p = pending ?: return PendingStep.Wait
        if (nowMs < openAtMs || open != null) return PendingStep.Wait
        if (manualPause) return drop()
        if (routeBusy) {
            if (nowMs >= dropAtMs) return drop()
            routeHeld = true
            return PendingStep.Wait
        }
        if (routeHeld) {
            routeHeld = false
            openAtMs = nowMs + OPEN_DELAY_MS
            return PendingStep.Wait
        }
        if (speechBusy && nowMs < openAtMs + SPEECH_MAX_WAIT_MS) return PendingStep.Wait
        pending = null
        return PendingStep.Open(p)
    }

    private fun drop(): PendingStep {
        pending = null
        routeHeld = false
        return PendingStep.Drop
    }

    /**
     * The caller opened [p] (spoke it, sent it to the screen) at [distanceM]: it counts. Its answer window has NOT
     * started: that waits for the question to be said ([startWindow]).
     */
    fun opened(p: Prompt, distanceM: Double) {
        nextId = maxOf(nextId, p.id + 1)
        count++
        lastOpenedMs = p.openedAtMs
        lastOpenedM = distanceM
        if (p.kind == PromptKind.last2k) last2kDone = true
        if (p.kind == PromptKind.behindTarget) behindAsked = true
        if (p.kind == PromptKind.betweenReps) repPrompts++
        open = p
        windowStartMs = null
        windowShiftMs = 0
        presses.reset()
    }

    /** True once the question has been said and the answer window is running. */
    val windowStarted: Boolean get() = open != null && windowStartMs != null

    /** The question is done at [nowMs]: the [Prompt.timeoutMs] window starts. A no-op when it already did. */
    fun startWindow(nowMs: Long) {
        if (open != null && windowStartMs == null) windowStartMs = nowMs
    }

    /** The run was paused for [deltaMs]: the window waits (a runner standing at the lights can still answer). */
    fun hold(deltaMs: Long) {
        if (open != null && windowStartMs != null && deltaMs > 0) windowShiftMs += deltaMs
    }

    /**
     * Once a tick at run time [nowMs]: a pause ([paused], auto or by hand) freezes the open window for the time since the
     * last tick ([hold]); an unbroken pause by hand ([manual]) past [MANUAL_PAUSE_CLOSE_MS] closes the open prompt as a
     * quiet hold ([manualPause]), returned for the caller to journal. Auto-pause (the lights) never closes it.
     */
    fun pauseTick(nowMs: Long, paused: Boolean, manual: Boolean): PromptAnswer? {
        val last = lastPauseTickMs ?: nowMs
        lastPauseTickMs = nowMs
        if (paused) hold(nowMs - last)
        val since = if (manual) manualSinceMs ?: nowMs else null
        manualSinceMs = since
        return since?.let { manualPause(nowMs - it, nowMs) }
    }

    /**
     * The runner has paused the run by hand for [pausedMs] so far (one unbroken pause) at [nowMs]. Past
     * [MANUAL_PAUSE_CLOSE_MS] the open prompt closes as a quiet hold: a water or cafe stop is not the time to answer,
     * and the headset buttons go back to the music app. A shorter stop (the lights) only freezes the window ([hold]).
     */
    fun manualPause(pausedMs: Long, nowMs: Long): PromptAnswer? {
        if (pausedMs < MANUAL_PAUSE_CLOSE_MS) return null
        return giveWay(nowMs)
    }

    /**
     * Something the runner must see or hear now took the screen (off route, the route's end): the open prompt closes as a
     * quiet hold, journaled as a timeout, with nothing said over the route's own line. Null when none is open.
     */
    fun giveWay(nowMs: Long): PromptAnswer? {
        val p = open ?: return null
        return resolve(p, PromptChoice.hold, PromptSource.timeout, nowMs).copy(quiet = true)
    }

    /** Ms left in the open prompt's window at [nowMs] (the whole window before it starts); null when none is open. */
    fun remainingMs(nowMs: Long): Long? {
        val p = open ?: return null
        val start = windowStartMs ?: return p.timeoutMs
        return (p.timeoutMs - (nowMs - start - windowShiftMs)).coerceIn(0, p.timeoutMs)
    }

    /** An answer from the screen ([index] = the button) or any source; null when [promptId] is not the open one. */
    fun answer(promptId: Int, index: Int, source: PromptSource, nowMs: Long): PromptAnswer? {
        val p = open ?: return null
        if (p.id != promptId) return null
        val choice = p.options.getOrNull(index) ?: return null
        return resolve(p, choice, source, nowMs)
    }

    /** A headset key that picks an option outright (MEDIA_NEXT = the second): answers at once. */
    fun headsetOption(index: Int, nowMs: Long): PromptAnswer? {
        val p = open ?: return null
        val choice = p.options.getOrNull(index) ?: return null
        return resolve(p, choice, PromptSource.headset, nowMs)
    }

    /** A counted headphone press at [nowMs]; the answer when it settles at once (a double press), else null (see [tick]). */
    fun headsetPress(nowMs: Long): PromptAnswer? {
        val p = open ?: return null
        val i = presses.press(nowMs) ?: return null
        return resolve(p, p.options[i.coerceAtMost(p.options.size - 1)], PromptSource.headset, nowMs)
    }

    /** True while a single headset press waits to learn if it is a double press. */
    val headsetPending: Boolean get() = presses.pending

    /**
     * Once per tick (or when the wait timer fires): a single press that waited alone, or the timeout. A press still
     * waiting when the window ends is an answer, not a timeout: a real input beats the clock.
     */
    fun tick(nowMs: Long): PromptAnswer? {
        val p = open ?: return null
        presses.poll(nowMs)?.let { i -> return resolve(p, p.options[i], PromptSource.headset, nowMs) }
        val start = windowStartMs ?: return null
        if (nowMs - start - windowShiftMs >= p.timeoutMs) {
            if (presses.pending) return resolve(p, p.options[0], PromptSource.headset, nowMs)
            return resolve(p, PromptChoice.hold, PromptSource.timeout, nowMs)
        }
        return null
    }

    private fun resolve(p: Prompt, choice: PromptChoice, source: PromptSource, nowMs: Long): PromptAnswer {
        val start = windowStartMs ?: p.openedAtMs
        open = null
        windowStartMs = null
        presses.reset()
        effect = effect.after(choice, p.kind)
        if (choice == PromptChoice.ease) easedOff = true
        return PromptAnswer(p, choice, source, nowMs, windowStartMs = start)
    }

    private fun gapName(f: KmFacts) = if (f.proxy) "${f.label} pace" else "best ${f.label}"

    /** "8 seconds up on your best 5K." in the chase wording (the same words as [ChaseCoach]). */
    private fun gapPhrase(f: KmFacts): String? {
        val gap = f.gapMs?.takeIf { f.chase } ?: return null
        val label = f.label ?: return null
        val s = abs(gap / 1_000.0).roundToLong()
        if (s < ChaseCoach.MIN_GAP_S) return null
        val g = CueWords.gap(s)
        val name = if (f.proxy) "your $label pace" else "your best $label"
        return if (gap < 0) "$g up on $name." else "$g off $name."
    }

    private fun toGoText(goal: Double, km: Int): String? {
        if (goal < MIN_GOAL_M) return null
        val left = goal - km * 1_000.0
        if (left <= 0 || left > ChaseCoach.LAST_STRETCH_M) return null
        val tenths = (left / 100.0).roundToInt()
        return if (tenths % 10 == 0) "${tenths / 10} k" else "${tenths / 10}.${tenths % 10} k"
    }

    companion object {
        const val MAX_PROMPTS = 3

        /** Of those, at most this many between reps. */
        const val MAX_REP_PROMPTS = 2
        const val TIMEOUT_MS = 8_000L

        /** Never in the first km: nothing before 1.5 km, so the km 1 mark itself (about 1 000 m) is inside it. */
        const val FIRST_KM_M = 1_500.0

        /** A decided prompt waits this long so the km cue and any moment overlay are gone first ([openTick])... */
        const val OPEN_DELAY_MS = 2_000L

        /** ...and no longer than this past it for speech to finish. */
        const val SPEECH_MAX_WAIT_MS = 6_000L

        /** A route cue holds it at most this long; then it is dropped (a minute later the moment has passed). */
        const val ROUTE_MAX_WAIT_MS = 60_000L

        /** A turn this close ahead is about to be said (the route's own turn cue is at 50 m): no question over it. */
        const val ROUTE_TURN_CLEAR_M = 100.0

        /**
         * A route cue the runner needs now or within seconds: off route, the end cue up, a turn [ROUTE_TURN_CLEAR_M] ahead,
         * or the trail ghost's TURN AROUND card ([trailTurnCue]).
         */
        fun routeBusy(off: Boolean, endCueUp: Boolean, turnInM: Double?, trailTurnCue: Boolean = false): Boolean =
            off || endCueUp || trailTurnCue || (turnInM != null && turnInM <= ROUTE_TURN_CLEAR_M)

        /** A manual pause this long with a prompt open closes it as a quiet hold ([manualPause]). */
        const val MANUAL_PAUSE_CLOSE_MS = 30_000L

        /** At least this much run time between two prompts. */
        const val MIN_GAP_MS = 240_000L

        /** And on distance runs at least this much distance. */
        const val MIN_GAP_M = 2_000.0

        /** Behind the target by this much (and still falling back) asks "push or ease off". */
        const val BEHIND_MS = 15_000L

        /** "Still falling back": the gap grew by this much since the last km. */
        const val GROWING_MS = 10_000L

        /** Ahead of the PB window by this much is a clear margin: "push or hold". */
        const val AHEAD_MS = 12_000L

        /** The goal's minimum for a last-2-km prompt, as for the chase line. */
        const val MIN_GOAL_M = ChaseCoach.MIN_GOAL_M

        /** The answered prompts of an earlier part of the run (journal `pr` lines), for [CoachPrompter]'s constructor. */
        fun restore(lines: List<JournalLine.PromptResolved>): List<PromptAnswer> = lines.mapNotNull { l ->
            val kind = PromptKind.entries.firstOrNull { it.key == l.trigger } ?: return@mapNotNull null
            val choice = PromptChoice.parse(l.choice) ?: return@mapNotNull null
            val options = l.options.mapNotNull { PromptChoice.parse(it) }
            PromptAnswer(
                Prompt(l.id, kind, l.km, options, "", l.openedAtMs),
                choice,
                PromptSource.parse(l.source) ?: PromptSource.timeout,
                l.atMs,
                windowStartMs = l.openedAtMs,
            )
        }

        /** The journal's `pr` line for [a]. */
        fun line(a: PromptAnswer, wallMs: Long, t: Long) = JournalLine.PromptResolved(
            t = t, w = wallMs, id = a.prompt.id, trigger = a.prompt.kind.key, km = a.prompt.km,
            options = a.prompt.options.map { it.key }, choice = a.choice.key, source = a.source.key,
            openedAtMs = a.prompt.openedAtMs, atMs = a.atMs,
        )
    }
}
