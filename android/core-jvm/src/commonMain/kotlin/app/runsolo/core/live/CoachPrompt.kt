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
 *  - [PromptKind.behindTarget]: behind the target by [BEHIND_MS] or more (push or ease off);
 *  - [PromptKind.aheadOfPb]: chase mode, ahead of the PB window by [AHEAD_MS] or more (push or hold);
 *  - [PromptKind.betweenReps]: an interval session, at a rep end that is not the last (push or hold).
 *
 * Limits: at most [MAX_PROMPTS] a run, at least [MIN_GAP_MS] of run time and (on distance runs) [MIN_GAP_M] between two,
 * never in the first km, never while one is open. On a distance goal the last slot is kept for the last 2 km, so a
 * runner who is behind all the way is not asked three times before the finish; and after an "ease off" the
 * falling-behind question is not asked again (they said they are easing). A prompt is open for [TIMEOUT_MS]; no
 * answer holds the current target.
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
) {
    /** The spoken acknowledgement. */
    val spoken: String
        get() = when {
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
data class PromptEffect(val paceFactor: Double = 1.0, val everyFactor: Double = 1.0) {
    /** The target pace (s/km) for the rest of the run; null stays null (no target to tighten). */
    fun targetPace(base: Double?): Double? = base?.times(paceFactor)

    /** The effect after [choice]: hold keeps this one. */
    fun after(choice: PromptChoice): PromptEffect = when (choice) {
        PromptChoice.push -> PUSH
        PromptChoice.ease -> EASE
        PromptChoice.hold -> this
    }

    companion object {
        val NONE = PromptEffect()

        /** 3 % faster than the target, a pace check every 30 s instead of 60. */
        val PUSH = PromptEffect(paceFactor = 0.97, everyFactor = 0.5)

        /** 4 % looser, a check every 90 s: calmer. */
        val EASE = PromptEffect(paceFactor = 1.04, everyFactor = 1.5)
    }
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
)

/**
 * The decision and the clock of the prompts for one run.
 *
 * [restored] = the journaled prompts of an earlier part of this run (after a kill): they count toward the cap and the
 * spacing, and the last push or ease keeps its effect. A prompt open at the kill is not reopened.
 */
class CoachPrompter(restored: List<PromptAnswer> = emptyList(), private val distanceGate: Boolean = true) {
    private var count = 0
    private var lastOpenedMs: Long? = null
    private var lastOpenedM: Double? = null
    private var nextId = 1
    private var last2kDone = false
    private var easedOff = false
    private val presses = HeadsetPresses()

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
            effect = effect.after(a.choice)
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
        if (!gapOk(nowMs, distanceM)) return null
        val phrase = gapPhrase(f)
        val toGo = f.goalDistanceM?.let { goal -> toGoText(goal, f.km) }
        if (toGo != null && !last2kDone) {
            val lead = if (phrase != null) "$toGo to go, $phrase" else "$toGo to go."
            return make(PromptKind.last2k, f.km, listOf(PromptChoice.push, PromptChoice.hold), "$lead Push or hold?", nowMs)
        }
        // The last slot of a distance goal is the last 2 km's.
        if (f.goalDistanceM != null && !last2kDone && count >= MAX_PROMPTS - 1) return null
        val behindMs = f.behindTargetMs ?: f.gapMs?.takeIf { f.chase }
        if (!easedOff && behindMs != null && behindMs >= BEHIND_MS) {
            val s = behindMs / 1_000
            val what = if (f.behindTargetMs != null) "behind the target" else "off your ${gapName(f)}"
            return make(PromptKind.behindTarget, f.km, listOf(PromptChoice.push, PromptChoice.ease), "${CueWords.gap(s)} $what. Push or ease off?", nowMs)
        }
        val gap = f.gapMs
        if (f.chase && gap != null && gap <= -AHEAD_MS) {
            return make(PromptKind.aheadOfPb, f.km, listOf(PromptChoice.push, PromptChoice.hold), "${phrase ?: ""} Push or hold?".trim(), nowMs)
        }
        return null
    }

    /** A rep ended in an interval session: [rep] of [reps]. Never after the last rep. */
    fun atRepEnd(rep: Int, reps: Int, nowMs: Long, distanceM: Double): Prompt? {
        if (rep >= reps || !gapOk(nowMs, distanceM)) return null
        return make(PromptKind.betweenReps, rep, listOf(PromptChoice.push, PromptChoice.hold), "Rep $rep done. Push the next one or hold?", nowMs)
    }

    private fun make(kind: PromptKind, km: Int, options: List<PromptChoice>, text: String, nowMs: Long) =
        Prompt(nextId, kind, km, options, text, nowMs)

    /** The caller opened [p] (spoke it, sent it to the screen) at [distanceM]: it counts and its clock starts. */
    fun opened(p: Prompt, distanceM: Double) {
        nextId = maxOf(nextId, p.id + 1)
        count++
        lastOpenedMs = p.openedAtMs
        lastOpenedM = distanceM
        if (p.kind == PromptKind.last2k) last2kDone = true
        open = p
        presses.reset()
    }

    /** An answer from the screen ([index] = the button) or any source; null when [promptId] is not the open one. */
    fun answer(promptId: Int, index: Int, source: PromptSource, nowMs: Long): PromptAnswer? {
        val p = open ?: return null
        if (p.id != promptId) return null
        val choice = p.options.getOrNull(index) ?: return null
        return resolve(p, choice, source, nowMs)
    }

    /** A headphone press at [nowMs]; the answer when it settles at once (a double press), else null (see [tickHeadset]). */
    fun headsetPress(nowMs: Long): PromptAnswer? {
        val p = open ?: return null
        val i = presses.press(nowMs) ?: return null
        return resolve(p, p.options[i.coerceAtMost(p.options.size - 1)], PromptSource.headset, nowMs)
    }

    /** True while a single headset press waits to learn if it is a double press. */
    val headsetPending: Boolean get() = presses.pending

    /** Once per tick (or when the wait timer fires): a single press that waited alone, or a timeout. */
    fun tick(nowMs: Long): PromptAnswer? {
        val p = open ?: return null
        presses.poll(nowMs)?.let { i -> return resolve(p, p.options[i], PromptSource.headset, nowMs) }
        if (nowMs - p.openedAtMs >= p.timeoutMs) return resolve(p, PromptChoice.hold, PromptSource.timeout, nowMs)
        return null
    }

    private fun resolve(p: Prompt, choice: PromptChoice, source: PromptSource, nowMs: Long): PromptAnswer {
        open = null
        presses.reset()
        effect = effect.after(choice)
        if (choice == PromptChoice.ease) easedOff = true
        return PromptAnswer(p, choice, source, nowMs)
    }

    private fun gapName(f: KmFacts) = if (f.proxy) "${f.label} pace" else "best ${f.label}"

    /** "8 seconds up on your best 5K." in the chase wording (the same words as [ChaseCoach]), without the closing full stop kept. */
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
        const val TIMEOUT_MS = 8_000L

        /** Never in the first km: nothing before 1.5 km, so the km 1 mark itself (about 1 000 m) is inside it. */
        const val FIRST_KM_M = 1_500.0

        /** At least this much run time between two prompts. */
        const val MIN_GAP_MS = 240_000L

        /** And on distance runs at least this much distance. */
        const val MIN_GAP_M = 1_000.0

        /** Behind the target by this much asks "push or ease off". */
        const val BEHIND_MS = 15_000L

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
