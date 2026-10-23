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
     * [plannedKind] (`easy` or `long`) and [plannedMinutes] turn on [PlannedTimeCues]; null (a
     * config persisted before they existed, or any other run) = no planned-time lines.
     * The start briefing ([app.runsolo.core.record.StartBriefing]): [briefingTemplate] (the coach's) and
     * [briefingFallback] (the app's own) are templates with slots; [sessionName], [plannedMinutes],
     * [plannedDistanceM], [reps] and [targetPaceSecPerKm] fill them. Both templates null = the usual start line.
     */
    data class Config(
        val full: Boolean,
        val targetPaceSecPerKm: Double? = null,
        val bandSecPerKm: Double = DEFAULT_BAND_SEC,
        val slowerIsFine: Boolean = false,
        val zoneBottomsBpm: List<Double>? = null,
        val plannedMaxZone: Int? = null,
        val plannedKind: String? = null,
        val plannedMinutes: Int? = null,
        val briefingTemplate: String? = null,
        val briefingFallback: String? = null,
        val plannedDistanceM: Double? = null,
        val reps: Int? = null,
        val sessionName: String? = null,
    ) {
        init {
            require(zoneBottomsBpm == null || zoneBottomsBpm.size == 4) { "zoneBottomsBpm is zones 2..5" }
        }
    }

    /**
     * One tick. [segment] identifies the rep or segment being run (a work step's index; 0 for a
     * run with no steps) and is null when nothing is coachable (paused, warm-up, recovery,
     * cool-down); [segmentActiveMs] is active time into it. [paceSecPerKm] is the live TRUE pace
     * ([LiveTruePace], the number the run screen shows), null when not moving or no pace yet. [hr]
     * null = no strap or a stale reading. [msToPhaseEnd] null = unknown or open-ended. [wideBand]:
     * a trail run or a grade over 3%, where the band widens to [WIDE_BAND_SEC].
     */
    data class Input(
        val t: Long,
        val segment: Int?,
        val segmentActiveMs: Long,
        val paceSecPerKm: Double?,
        val hr: Double?,
        val msToPhaseEnd: Long?,
        val busyUntil: Long,
        val wideBand: Boolean = false,
    )

    enum class Kind { drift, status }

    data class Line(val kind: Kind, val text: String)

    private var segment: Int? = null

    // A mid-run prompt's effect (push / ease off): a factor on the target pace and on the gap between pace checks.
    private var effect = PromptEffect.NONE

    /** A one-rep effect lives until the segment after the one it first sees. */
    private var effectSegment: Int? = null

    /**
     * The runner answered a two-button prompt ([CoachPrompter]). The effect applies to the plan's own target only: a run
     * with no target (a Free run) gets nothing new, so an answer never switches pace checks on. A push is applied only
     * while the runner is within [PUSH_WITHIN_SEC] of the target (a runner already far off the target gets no tighter
     * one to be scolded by); an ease off loosens the target, quietens "Pick it up" and spaces the checks. The pace
     * trackers restart. Returns the effect that actually applies, for the screen's target band.
     */
    fun applyEffect(e: PromptEffect): PromptEffect {
        val target = config.targetPaceSecPerKm
        val avg = if (window.size >= MIN_SAMPLES) window.average() else null
        val applied = when {
            target == null || e == PromptEffect.NONE -> PromptEffect.NONE
            e.quietSlow -> e
            avg == null || avg - target <= PUSH_WITHIN_SEC -> e
            else -> PromptEffect.NONE
        }
        effect = applied
        effectSegment = null
        checked = false
        offStreak = 0
        dueSinceT = null
        return applied
    }

    /** The target the checks use now: the plan's, times the effect's factor. */
    private val targetPace: Double?
        get() = config.targetPaceSecPerKm?.let { effect.targetPace(it) }

    fun tick(i: Input): Line? {
        if (!config.full) return null
        if (i.segment != segment) {
            segment = i.segment
            nextEvalMs = FIRST_EVAL_MS
            dueSinceT = null
            lastWasOnPace = false
            window.clear()
            nextCheckMs = CHECK_EVERY_MS
            checked = false
            offStreak = 0
        }
        if (i.segment == null) {
            aboveSinceT = null
            return null
        }
        // A between-reps answer lasts one rep: it is gone once the segment after the first one it saw begins.
        if (effect.oneRep) {
            val seen = effectSegment
            if (seen == null) effectSegment = i.segment else if (seen != i.segment) {
                effect = PromptEffect.NONE
                effectSegment = null
            }
        }
        i.paceSecPerKm?.let {
            window.addLast(it)
            while (window.size > WINDOW_SAMPLES) window.removeFirst()
        }
        check(i)
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

    /**
     * A pace check every [CHECK_EVERY_MS]: the smoothed pace against the target band. Off the band the
     * same way twice running is what makes a line; one noisy check never does.
     */
    private fun check(i: Input) {
        val target = targetPace ?: return
        if (i.paceSecPerKm == null || i.segmentActiveMs < nextCheckMs || window.size < MIN_SAMPLES) return
        nextCheckMs = i.segmentActiveMs + CHECK_EVERY_MS
        checkDelta = window.average() - target
        val band = if (i.wideBand) maxOf(config.bandSecPerKm, WIDE_BAND_SEC) else config.bandSecPerKm
        val dir = when {
            checkDelta < -band -> -1
            checkDelta > band && !config.slowerIsFine -> 1
            else -> 0
        }
        offStreak = if (dir != 0 && checked && dir == checkDir) offStreak + 1 else if (dir != 0) 1 else 0
        checkDir = dir
        checked = true
    }

    private fun status(i: Input, quiet: Boolean): Line? {
        if (targetPace == null || !checked || i.paceSecPerKm == null) return null
        if (i.segmentActiveMs < nextEvalMs) return null
        if (checkDir != 0 && offStreak < 2) return null // wait for the second check
        if (i.msToPhaseEnd != null && i.msToPhaseEnd <= NEAR_END_MS) return null
        val due = dueSinceT ?: i.t.also { dueSinceT = it }
        // Could not start in time: the moment has passed, so skip this slot rather than say it late.
        if (i.t - due > SpeechClock.STALE_MS) {
            skipSlot(i)
            return null
        }
        if (!quiet) return null
        skipSlot(i)
        val secs = maxOf(1L, abs(checkDelta).roundToLong())
        val unit = if (secs == 1L) "second" else "seconds"
        return when (checkDir) {
            -1 -> {
                lastWasOnPace = false
                Line(Kind.status, "Ease off, $secs $unit fast")
            }
            1 -> {
                // After "ease off" the coach does not say "Pick it up" for the rest of the run.
                if (effect.quietSlow) return null
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
        nextEvalMs = i.segmentActiveMs + (EVERY_MS * effect.everyFactor).toLong()
        dueSinceT = null
    }

    companion object {
        /** A push tightens the target only while the runner is within this of it (s/km). */
        const val PUSH_WITHIN_SEC = 10.0

        /** The target band when the plan has none: ±5 s/km. */
        const val DEFAULT_BAND_SEC = 5.0

        /** The first status check, into each rep or segment. */
        const val FIRST_EVAL_MS = 30_000L

        /** The pace is smoothed over this many moving ticks (about 30 s at 1 Hz). */
        const val WINDOW_SAMPLES = 30

        /** Fewer smoothed ticks than this and there is no pace worth judging yet. */
        const val MIN_SAMPLES = 10

        /** The smoothed pace is checked against the band this often; two off-band checks in a row make a line. */
        const val CHECK_EVERY_MS = 15_000L

        /** The band on a trail run or above 3% grade. */
        const val WIDE_BAND_SEC = 8.0

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
