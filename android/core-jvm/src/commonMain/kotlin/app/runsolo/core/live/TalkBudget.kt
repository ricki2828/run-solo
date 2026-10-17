package app.runsolo.core.live

import kotlin.math.abs

/**
 * Settings → Voice → "Voice detail": how much a run says. [key] is the stable name stored in settings;
 * it reaches Kotlin as a `voice:<key>` entry in the check-in's metric list (unknown keys are ignored by
 * [CheckInMetric.parse], so older builds are unaffected).
 *
 *  - [coach]: the km line trimmed to one lead item, news-only half kms, and trail moments, all arbitrated by [TalkBudget].
 *  - [everything]: today's full check-in; the budget only de-dupes.
 *  - [minimal]: the km word and structure cues (turns, off route, interval steps) only.
 */
enum class VoiceLevel(val key: String) {
    coach("coach"),
    everything("everything"),
    minimal("minimal"),
    ;

    /** The metric-list entry that carries this level over Pigeon. */
    val metricKey: String get() = "$PREFIX$key"

    companion object {
        /** The level a runner gets until they pick one. One line on purpose: Ricki has not confirmed Coach as the default yet. */
        val DEFAULT: VoiceLevel = coach

        const val PREFIX = "voice:"

        /** The level carried in a check-in's metric keys; null when none is (a build from before this setting). */
        fun fromMetricKeys(keys: Collection<String?>): VoiceLevel? {
            val k = keys.firstOrNull { it != null && it.startsWith(PREFIX) }?.removePrefix(PREFIX) ?: return null
            return entries.firstOrNull { it.key == k }
        }
    }
}

/**
 * What a spoken line is, and so how much it matters. P0 structure and safety never wait and are never
 * dropped; P1 game beats wait up to [TalkBudget.holdMs] for a gap; the rest are dropped, never queued.
 */
enum class CueSlot(val priority: Int) {
    turnaround(0),
    offRoute(0),
    routeEnd(0),
    finish(0),

    /** Interval and plan cues: the next step, rep ends, countdowns, goal reached. */
    structure(0),
    climbAhead(1),
    climbDone(1),

    /** A quest completed mid-run: a game beat, said once when a gap opens. */
    questDone(1),
    ghostFlip(1),
    finalPush(1),
    summit(2),
    ghostGap(2),
    zoneDrift(2),
    paceStatus(2),
    km(3),
    halfKm(4),
}

/**
 * One line asking to be said. [key] = `slot:id`; a key already said is not said again unless [value] has moved
 * by [minChange] since (zone 1, gap 15 s, climb 40 m, height 50 m). A null [minChange] = once per key.
 */
data class TalkLine(
    val slot: CueSlot,
    val key: String,
    val text: String,
    val value: Double? = null,
    val minChange: Double? = null,
    /** A km line carrying a board compare: never merged with an event (a merge would cut the comparison). */
    val whole: Boolean = false,
    /** How long a blocked P1 line waits for a gap before it is dropped; null = the budget's [TalkBudget.HOLD_MS]. */
    val holdMs: Long? = null,
) {
    val words: Int get() = CueComposer.words(text)
}

/**
 * The one arbiter of what a run says (cadence v1, `cadence.md` §4): priority, de-dupe, a minimum gap, a words
 * budget and a hard-effort mute. Pure and JVM-tested; [app.runsolo.record.CuePlayer] holds one and every spoken line
 * (km, half km, trail moments, turns, off route, interval cues, coaching lines) goes through it, so nothing
 * double-speaks.
 *
 * Rules for [VoiceLevel.coach] (the others are in [VoiceLevel]):
 *  - P0 always speaks. Its words do not use the budget, but its time counts for the gap.
 *  - Non-P0 lines keep [minGapMs] of silence after whatever was last said (the speech still queued included).
 *    A blocked P1 line is held up to [holdMs] and said when the gap opens; a blocked P2+ line is dropped.
 *  - Non-P0 P2-P4 lines share [windowWords] words per rolling [windowMs]; over it they are dropped. P1 beats are exempt.
 *  - P3-P4 (km, half km) are silent while the runner is working hard (steep and zone 4+): [offer]'s `hardEffort`.
 *  - A held event that is waiting when the km line comes is merged into it ([merge]): one utterance, never two.
 */
class TalkBudget(
    var level: VoiceLevel = VoiceLevel.everything,
    private val minGapMs: Long = MIN_GAP_MS,
    private val windowMs: Long = WINDOW_MS,
    private val windowWords: Int = WINDOW_WORDS,
    private val holdMs: Long = HOLD_MS,
) {
    private val spoken = ArrayDeque<Pair<Long, Int>>()
    private val said = HashMap<String, Double?>()
    private var lastEndMs = Long.MIN_VALUE / 2
    private var held: TalkLine? = null
    private var heldAtMs = 0L

    /**
     * Asks to say [line] at [now] with the player busy until [busyUntil] (a [SpeechClock] time). Returns the line to
     * say (for a merge, the merged one: say that, not [line]) or null: drop it. A returned line is recorded as said.
     */
    fun offer(line: TalkLine, now: Long, busyUntil: Long, hardEffort: Boolean = false): TalkLine? {
        if (line.slot.priority == 0) return accept(line, now, busyUntil)
        when (level) {
            VoiceLevel.minimal -> return if (line.slot == CueSlot.km) accept(line, now, busyUntil) else null
            VoiceLevel.everything -> return if (repeats(line)) null else accept(line, now, busyUntil)
            VoiceLevel.coach -> Unit
        }
        if (repeats(line)) return null
        if (hardEffort && line.slot.priority >= 3) return null
        held?.let { if (now - heldAtMs > (it.holdMs ?: holdMs)) held = null }
        // A km line that finds an event waiting takes it along: one utterance.
        val waiting = held
        if (waiting != null && line.slot == CueSlot.km && !line.whole && gapOpen(now, busyUntil)) {
            held = null
            return accept(merge(line, waiting), now, busyUntil)
        }
        if (line.slot.priority >= 2 && overWindow(line, now)) return null
        // A km line carrying a board compare is the one chance to say it (the compare is claimed once): it skips the gap.
        if (!line.whole && !gapOpen(now, busyUntil)) {
            // A completed quest takes the held slot from another game beat: it happens once, the others come round again.
            if (line.slot.priority == 1 && (held == null || line.slot == CueSlot.questDone)) {
                held = line
                heldAtMs = now
            }
            return null
        }
        return accept(line, now, busyUntil)
    }

    /** [line] is being said regardless (a nudge riding its km cue, a goal, a summary): counted for the gap and the words, never gated. */
    fun record(line: TalkLine, now: Long, busyUntil: Long) {
        accept(line, now, busyUntil)
    }

    /** Once a tick: the held P1 line, if the gap has opened; dropped after [holdMs]. */
    fun poll(now: Long, busyUntil: Long): TalkLine? {
        val h = held ?: return null
        if (now - heldAtMs > (h.holdMs ?: holdMs)) {
            held = null
            return null
        }
        if (level != VoiceLevel.coach) {
            held = null
            return null
        }
        if (!gapOpen(now, busyUntil)) return null
        held = null
        return accept(h, now, busyUntil)
    }

    /** True when [line] was said and has not moved far enough to be said again. */
    private fun repeats(line: TalkLine): Boolean {
        if (line.key !in said) return false
        val last = said[line.key]
        val step = line.minChange
        val v = line.value
        return v == null || step == null || last == null || abs(v - last) < step
    }

    /** [busyUntil] only counts while speech is still queued; an idle player (0 or in the past) is not a line just said. */
    private fun gapOpen(now: Long, busyUntil: Long): Boolean = now >= maxOf(lastEndMs, if (busyUntil > now) busyUntil else Long.MIN_VALUE / 2) + minGapMs

    private fun pruneWindow(now: Long) {
        while (spoken.isNotEmpty() && spoken.first().first <= now - windowMs) spoken.removeFirst()
    }

    /** When a non-P0 line could next be said, given speech queued until [busyUntil]; callers that own their own cooldown wait for it. */
    fun gapOpensAt(now: Long, busyUntil: Long): Long = maxOf(lastEndMs, if (busyUntil > now) busyUntil else Long.MIN_VALUE / 2) + minGapMs

    private fun overWindow(line: TalkLine, now: Long): Boolean {
        pruneWindow(now)
        return spoken.sumOf { it.second } + line.words > windowWords
    }

    private fun accept(line: TalkLine, now: Long, busyUntil: Long): TalkLine {
        // P0 lines are never checked for repeats, so their keys are not kept (a run of announces stays bounded).
        if (line.slot.priority > 0) said[line.key] = line.value
        pruneWindow(now)
        if (line.slot.priority > 0) spoken.addLast(now to line.words)
        lastEndMs = maxOf(now, busyUntil, lastEndMs) + line.words * SpeechClock.MS_PER_WORD
        return line
    }

    /** Forgets what was said (a new run). */
    fun reset() {
        spoken.clear()
        said.clear()
        held = null
        lastEndMs = Long.MIN_VALUE / 2
    }

    companion object {
        const val MIN_GAP_MS = 25_000L
        const val WINDOW_MS = 180_000L
        const val WINDOW_WORDS = 30
        const val HOLD_MS = 10_000L

        /** A km line and an event in one utterance stay within this many words. */
        const val MERGE_MAX_WORDS = 14

        /**
         * "4 k. 31 minutes. 12 up on your best." + "Climb ahead. 300 metres, 40 up." -> "4 k. Climb ahead. 300 metres, 40 up.":
         * the km line shrinks to its first sentence and the event follows, in one line of at most [MERGE_MAX_WORDS] words.
         * If even that is too long the event is dropped and the km line is said whole.
         */
        fun merge(km: TalkLine, event: TalkLine): TalkLine {
            if (km.whole) return km
            val short = km.text.trim().substringBefore(". ").let { if (it.endsWith(".")) it else "$it." }
            val text = "$short ${event.text.trim()}"
            return if (CueComposer.words(text) <= MERGE_MAX_WORDS) km.copy(slot = event.slot, key = event.key, text = text) else km
        }
    }
}

/**
 * Says "ahead of your best" or "behind" only when it is true for good: the side must hold for [holdMs] with a margin of
 * [marginSec], and a flip is not said again within [minFlipGapM]. A drifting ghost kills trust, so a noisy trace
 * around level says nothing. The first side seen is the baseline and is not a flip.
 */
class AheadBehindGate(
    private val marginSec: Double = 5.0,
    private val holdMs: Long = 30_000L,
    private val minFlipGapM: Double = 500.0,
) {
    private var side = 0
    private var pending = 0
    private var pendingSinceMs = 0L
    private var lastFlipDistM = Double.NEGATIVE_INFINITY

    /** [gapSec] positive = ahead. Returns +1 (now ahead) or -1 (now behind) once per confirmed flip, else null. */
    fun update(nowMs: Long, distM: Double, gapSec: Double): Int? {
        val candidate = when {
            gapSec >= marginSec -> 1
            gapSec <= -marginSec -> -1
            else -> 0
        }
        if (candidate == 0 || candidate == side) {
            pending = 0
            return null
        }
        if (candidate != pending) {
            pending = candidate
            pendingSinceMs = nowMs
        }
        if (nowMs - pendingSinceMs < holdMs) return null
        val first = side == 0
        side = candidate
        pending = 0
        if (first) return null
        if (distM - lastFlipDistM < minFlipGapM) return null
        lastFlipDistM = distM
        return candidate
    }
}
