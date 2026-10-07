package app.runsolo.core.live

import kotlin.math.abs
import kotlin.math.roundToLong

/**
 * Voice coaching during a run: target status and heart-rate zone drift, said as short lines on the
 * recorder's 1 Hz tick so they work with the screen off. The third coaching line, the next step,
 * is the ten-seconds cue itself (`CueWords.nextStep`), so there is only one voice for it.
 *
 * Rules: a line is only returned when no speech is queued ([Input.busyUntil]), so coaching never
 * piles up behind a cue and a status line that could not start within [STALE_MS] of being due is
 * dropped. Priority is next step (the cue, always first: nothing is said within [NEAR_END_MS] of
 * a part ending) > drift > status. Replays and Minimal detail never construct one that speaks.
 */
class VoiceCoach(private val config: Config) {
    /**
     * [full] false = Minimal (next step only): this class says nothing. [targetPaceSecPerKm] null =
     * no target status. [slowerIsFine]: an easy-run ceiling, slow is on target. [zoneBottomsBpm] =
     * the bottoms of zones 2..5 (as `HrZones`); with [plannedMaxZone] it turns drift on.
     */
    data class Config(
        val full: Boolean,
        val targetPaceSecPerKm: Double? = null,
        val bandSecPerKm: Double = DEFAULT_BAND_SEC,
        val slowerIsFine: Boolean = false,
        val zoneBottomsBpm: List<Double>? = null,
        val plannedMaxZone: Int? = null,
    ) {
        init {
            require(zoneBottomsBpm == null || zoneBottomsBpm.size == 4) { "zoneBottomsBpm is zones 2..5" }
        }
    }

    /**
     * One tick. [segment] identifies the rep or segment being run (a work step's index; 0 for a
     * run with no steps) and is null when nothing is coachable (paused, warm-up, recovery,
     * cool-down); [segmentActiveMs] is active time into it. [paceSecPerKm] null = no pace now.
     * [hr] null = no strap or a stale reading. [msToPhaseEnd] null = unknown or open-ended.
     */
    data class Input(
        val t: Long,
        val segment: Int?,
        val segmentActiveMs: Long,
        val paceSecPerKm: Double?,
        val hr: Double?,
        val msToPhaseEnd: Long?,
        val busyUntil: Long,
    )

    enum class Kind { drift, status }

    data class Line(val kind: Kind, val text: String)

    private var segment: Int? = null
    private var nextEvalMs = FIRST_EVAL_MS
    private var dueSinceT: Long? = null
    private var lastWasOnPace = false
    private var aboveSinceT: Long? = null
    private var lastDriftT: Long? = null

    fun tick(i: Input): Line? {
        if (!config.full) return null
        if (i.segment != segment) {
            segment = i.segment
            nextEvalMs = FIRST_EVAL_MS
            dueSinceT = null
            lastWasOnPace = false
        }
        if (i.segment == null) {
            aboveSinceT = null
            return null
        }
        val drift = driftAbove(i)
        val quiet = i.busyUntil <= i.t && (i.msToPhaseEnd == null || i.msToPhaseEnd > NEAR_END_MS)
        // Drift first: it outranks status, and a status that comes due while it speaks goes stale.
        if (drift != null && quiet && drift.firesAt <= i.t) {
            lastDriftT = i.t
            return Line(Kind.drift, "Heart rate in zone ${drift.zone}. Ease back to zone ${config.plannedMaxZone}.")
        }
        return status(i, quiet)
    }

    private class Drift(val zone: Int, val firesAt: Long)

    /** The zone above plan and when the line may fire; null when not above, or drift is off. */
    private fun driftAbove(i: Input): Drift? {
        val planned = config.plannedMaxZone
        val bottoms = config.zoneBottomsBpm
        val hr = i.hr
        if (planned == null || bottoms == null || hr == null) {
            aboveSinceT = null
            return null
        }
        val zone = (5 downTo 2).firstOrNull { hr >= bottoms[it - 2] } ?: 1
        if (zone <= planned) {
            aboveSinceT = null
            return null
        }
        val since = aboveSinceT ?: i.t.also { aboveSinceT = it }
        val coolOff = lastDriftT?.let { it + DRIFT_EVERY_MS } ?: Long.MIN_VALUE
        return Drift(zone, maxOf(since + DRIFT_AFTER_MS, coolOff))
    }

    private fun status(i: Input, quiet: Boolean): Line? {
        val target = config.targetPaceSecPerKm ?: return null
        if (i.segmentActiveMs < nextEvalMs) return null
        val pace = i.paceSecPerKm ?: return null
        if (i.msToPhaseEnd != null && i.msToPhaseEnd <= NEAR_END_MS) return null
        val due = dueSinceT ?: i.t.also { dueSinceT = it }
        if (!quiet) {
            // Could not start in time: the moment has passed, so skip this slot rather than say it late.
            if (i.t - due > SpeechClock.STALE_MS) skipSlot(i)
            return null
        }
        skipSlot(i)
        val delta = pace - target
        val band = config.bandSecPerKm
        val secs = maxOf(1L, abs(delta).roundToLong())
        val unit = if (secs == 1L) "second" else "seconds"
        return when {
            delta < -band -> {
                lastWasOnPace = false
                Line(Kind.status, "Ease off, $secs $unit fast")
            }
            delta > band && !config.slowerIsFine -> {
                lastWasOnPace = false
                Line(Kind.status, "Pick it up, $secs $unit slow")
            }
            else -> {
                // On pace twice in a row: nothing to add.
                val said = if (lastWasOnPace) null else Line(Kind.status, "On pace")
                lastWasOnPace = true
                said
            }
        }
    }

    private fun skipSlot(i: Input) {
        nextEvalMs = i.segmentActiveMs + EVERY_MS
        dueSinceT = null
    }

    companion object {
        /** The target band when the plan has none: ±5 s/km. */
        const val DEFAULT_BAND_SEC = 5.0

        /** The first status check, into each rep or segment. */
        const val FIRST_EVAL_MS = 30_000L

        /** Then one check a minute. */
        const val EVERY_MS = 60_000L

        /** Nothing coaching is said this close to a part ending: the next-step cue owns that moment. */
        const val NEAR_END_MS = 12_000L

        /** Continuously above the planned zone this long before the drift line. */
        const val DRIFT_AFTER_MS = 60_000L

        /** At most one drift line per this. */
        const val DRIFT_EVERY_MS = 180_000L
    }
}
