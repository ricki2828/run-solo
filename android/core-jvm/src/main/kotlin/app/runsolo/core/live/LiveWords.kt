package app.runsolo.core.live

import app.runsolo.core.record.CueWords
import kotlin.math.abs
import kotlin.math.roundToInt
import kotlin.math.roundToLong

/**
 * What a live compare says (Phase 4 §3.2 copy table): plain, casual, no em dashes. Appended to
 * the cue that already speaks (a km, a rep end, a Cooper minute) by [CueComposer], which keeps
 * the whole cue to [CueComposer.MAX_WORDS]; [LiveWordsTest] fills every template with its
 * longest numbers and checks that it fits.
 */
object LiveWords {
    /** The base cue for a Free or Laps km that has something to compare (no km cue otherwise). */
    fun km(km: Int): String = "$km k."

    /** At the board's own distance (5 k of the 5K board): "5K in 24:10, your number 2." */
    fun finish(r: CompareResult, activeMs: Long): String {
        val time = CueWords.clock(activeMs.toDouble())
        return if (r.of > 2) "${r.boardLabel} in $time, your number ${r.rank}." else "${r.boardLabel} in $time. ${compare(r)}"
    }

    fun compare(r: CompareResult): String = when (r.kind) {
        CompareKind.distance -> distance(r)
        CompareKind.intervals -> intervals(r)
        CompareKind.cooper -> cooper(r)
        CompareKind.target -> target(r)
    }

    private fun seconds(ms: Long): Long = abs(ms / 1_000.0).roundToLong()

    private fun secondsWord(s: Long) = if (s == 1L) "1 second" else "$s seconds"

    private fun distance(r: CompareResult): String {
        val d = r.deltaMs!!
        val s = seconds(d)
        return if (r.of > 2) {
            val gap = when {
                s == 0L -> "Level with your best."
                d < 0 -> "${secondsWord(s)} up on your best."
                else -> "${secondsWord(s)} behind your best."
            }
            "On pace for number ${r.rank} of ${r.of}. $gap"
        } else {
            when {
                s == 0L -> "Level with your only other ${r.boardLabel}."
                d < 0 -> "${secondsWord(s)} up on your only other ${r.boardLabel}."
                else -> "${secondsWord(s)} behind your only other ${r.boardLabel}."
            }
        }
    }

    private fun intervals(r: CompareResult): String {
        val d = r.deltaSecPerKm!!
        return if (r.of > 2) {
            when (r.rank) {
                1 -> "Best start to this session you've had."
                else -> "Number ${r.rank} of ${r.of} after ${r.index} ${if (r.index == 1) "rep" else "reps"}."
            }
        } else {
            when {
                abs(d) < 0.5 -> "Level with your last one so far."
                d < 0 -> "Ahead of your last one so far."
                else -> "Behind your last one so far."
            }
        }
    }

    private fun cooper(r: CompareResult): String = if (r.of > 2) {
        when (r.rank) {
            1 -> "Best so far."
            2 -> "Second best so far."
            3 -> "Third best so far."
            else -> "Number ${r.rank} of ${r.of} so far."
        }
    } else {
        val gap = r.deltaVo2!!.roundToInt()
        when {
            gap == 0 -> "Level with last time."
            gap > 0 -> "Up $gap on last time."
            else -> "Down ${-gap} on last time."
        }
    }

    private fun target(r: CompareResult): String {
        val d = r.deltaMs!!
        val s = seconds(d)
        val what = "your ${r.boardLabel} ${CueWords.clock(r.value!!)}"
        return when {
            s == 0L -> "Level with $what."
            d < 0 -> "${secondsWord(s)} up on $what."
            else -> "${secondsWord(s)} behind $what."
        }
    }
}

/**
 * One spoken cue with its extras (WARN-2): at most [MAX_WORDS] words (about 6 s at the TTS
 * rate). Priority base > compare > nudge; an extra that would go over is dropped, never queued
 * as a cue of its own.
 */
object CueComposer {
    const val MAX_WORDS = 16

    data class Composed(val text: String?, val compareSpoken: Boolean, val nudgeSpoken: Boolean)

    fun words(s: String?): Int = s?.trim()?.split(Regex("\\s+"))?.count { it.isNotEmpty() } ?: 0

    fun compose(base: String?, compare: String? = null, nudge: String? = null): Composed {
        var text = base
        var withCompare = false
        var withNudge = false
        if (compare != null && words(text) + words(compare) <= MAX_WORDS) {
            text = join(text, compare)
            withCompare = true
        }
        if (nudge != null && words(text) + words(nudge) <= MAX_WORDS) {
            text = join(text, nudge)
            withNudge = true
        }
        return Composed(text, withCompare, withNudge)
    }

    private fun join(a: String?, b: String): String = when {
        a.isNullOrBlank() -> b
        a.trimEnd().endsWith('.') -> "${a.trimEnd()} $b"
        else -> "${a.trimEnd()}. $b"
    }
}
