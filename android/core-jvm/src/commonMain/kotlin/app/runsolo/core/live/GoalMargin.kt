package app.runsolo.core.live

import app.runsolo.core.model.LiveTarget
import app.runsolo.core.record.CueWords
import kotlin.math.abs
import kotlin.math.roundToLong

/** Where the cumulative margin to a goal time is heading, read from one km's change in it. */
enum class MarginTrend { growing, steady, shrinking }

/**
 * A goal run with a target time: how far ahead of (or behind) the goal clock the runner is, which way
 * that is heading, and the words for it. Descriptive only: it names the target and never gives an order.
 * Shared by [VoiceCoach] (status lines) and [CoachPrompter] (prompt text) so they say it the same way.
 */
object GoalMargin {
    /** A margin or a km-to-km change inside this is level / steady. */
    const val DEAD_BAND_MS = 3_000L

    /** Once "on pace", the runner stays level until the margin passes this (hysteresis: no flip at the 3 s edge). */
    const val LEVEL_EXIT_MS = 5_000L

    /** Past this far behind, a status line is said once a km at most. */
    const val FAR_BEHIND_MS = 60_000L

    /** Ms ahead of the goal clock (negative = behind) at [distanceM] after [elapsedMs]: the even split minus the time taken. */
    fun aheadMs(target: LiveTarget, distanceM: Double, elapsedMs: Long): Long =
        (target.targetMs * (distanceM / target.distanceM)).toLong() - elapsedMs

    /** [changeMs] = the ahead margin now minus the margin one km ago. */
    fun trend(changeMs: Long): MarginTrend = when {
        changeMs >= DEAD_BAND_MS -> MarginTrend.growing
        changeMs <= -DEAD_BAND_MS -> MarginTrend.shrinking
        else -> MarginTrend.steady
    }

    /**
     * "20 seconds ahead of 24:30, margin shrinking", "10 seconds behind 24:30, holding", "On 24:30 pace".
     * [changeMs] null = no trend yet (the first km): the trend part is left out. [level] = on pace (default: inside
     * the dead band; [VoiceCoach] passes its hysteresis). [predicted] = say "your predicted" before the time: the
     * first line only, the target being a prediction the runner saw on Start. At most 9 words.
     */
    fun phrase(
        aheadMs: Long,
        changeMs: Long?,
        targetMs: Long,
        level: Boolean = abs(aheadMs) < DEAD_BAND_MS,
        predicted: Boolean = false,
    ): String {
        val t = CueWords.clock(targetMs.toDouble()).let { if (predicted) "your predicted $it" else it }
        if (level) {
            // Level now but not holding: say which way it is going.
            val way = changeMs?.let { trend(it) }
            return when (way) {
                MarginTrend.shrinking -> "On $t pace, slipping"
                MarginTrend.growing -> "On $t pace, gaining"
                else -> "On $t pace"
            }
        }
        val ahead = aheadMs > 0
        val s = abs(aheadMs / 1_000.0).roundToLong()
        val head = "${CueWords.gap(s)} ${if (ahead) "ahead of" else "behind"} $t"
        val tail = changeMs?.let { c ->
            when (trend(c)) {
                MarginTrend.steady -> "holding"
                MarginTrend.growing -> if (ahead) "margin growing" else "closing"
                MarginTrend.shrinking -> if (ahead) "margin shrinking" else "slipping"
            }
        }
        return if (tail == null) head else "$head, $tail"
    }

    /** The one line said when the goal time is re-aimed: "New target: 8 k in 52 minutes." */
    fun newTargetLine(distanceM: Double, targetMs: Long): String {
        val km = distanceM / 1_000
        val dist = if (km % 1.0 == 0.0) "${km.toInt()}" else "${(km * 10).roundToLong() / 10.0}"
        val total = targetMs / 60_000
        val h = total / 60
        val m = total % 60
        val minutes = if (m == 1L) "1 minute" else "$m minutes"
        val time = when {
            h == 0L -> minutes
            m == 0L -> if (h == 1L) "1 hour" else "$h hours"
            else -> "${if (h == 1L) "1 hour" else "$h hours"} $minutes"
        }
        return "New target: $dist k in $time."
    }

    /**
     * The last-2-km prompt's version, where "under" is ahead of the goal clock: "12 seconds under 24:30, shrinking",
     * "18 seconds over 24:30", "level with 24:30". The trend is only said for a lead that is shrinking.
     */
    fun promptPhrase(aheadMs: Long, changeMs: Long?, targetMs: Long): String {
        val t = CueWords.clock(targetMs.toDouble())
        if (abs(aheadMs) < DEAD_BAND_MS) {
            return if (changeMs != null && trend(changeMs) == MarginTrend.shrinking) "level with $t, slipping" else "level with $t"
        }
        val s = CueWords.gap(abs(aheadMs / 1_000.0).roundToLong())
        if (aheadMs < 0) return "$s over $t"
        return if (changeMs != null && trend(changeMs) == MarginTrend.shrinking) "$s under $t, shrinking" else "$s under $t"
    }
}
