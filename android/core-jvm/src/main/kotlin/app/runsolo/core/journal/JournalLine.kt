package app.runsolo.core.journal

import app.runsolo.core.model.CueKind
import app.runsolo.core.model.LapSource
import app.runsolo.core.model.LiveContext
import app.runsolo.core.model.RunMode
import app.runsolo.core.model.SessionSpec
import app.runsolo.core.model.Units

/**
 * One NDJSON line of `runs/<id>/journal.ndjson`.
 *
 * Every line carries `t` = device monotonic millis (from `elapsedRealtimeNanos`, never wall
 * clock) and `w` = wall-clock epoch millis. `t` drives the run timeline; `w` is only used to
 * size a kill→resume gap and to age an orphaned journal, because `elapsedRealtime` restarts
 * at zero after a reboot.
 */
sealed class JournalLine {
    abstract val t: Long
    abstract val w: Long

    data class Header(
        override val t: Long,
        override val w: Long,
        val id: String,
        val device: String,
        val app: String,
        val tz: String,
        val mode: RunMode,
        /** The full expanded session (schema 3), so restore needs nothing else. */
        val session: SessionSpec?,
        val units: Units,
    ) : JournalLine()

    /**
     * One 1 Hz tick. With a fix: the raw location (nothing is filtered before journaling so
     * acceptance is repeatable). Without a fix (treadmill, tunnel, GPS dropout): lat/lon/acc
     * null, so elapsed time and HR are still recorded and the engine can see the fix ratio.
     */
    data class Sample(
        override val t: Long,
        override val w: Long,
        val lat: Double?,
        val lon: Double?,
        val altM: Double?,
        val accuracyM: Double?,
        val speedMps: Double?,
        val hr: Int?,
    ) : JournalLine() {
        val hasFix: Boolean get() = lat != null && lon != null && accuracyM != null

        companion object {
            fun noFix(t: Long, w: Long, hr: Int?) = Sample(t, w, null, null, null, null, null, hr)
        }
    }

    data class Lap(override val t: Long, override val w: Long, val source: LapSource) : JournalLine()

    data class Pause(override val t: Long, override val w: Long) : JournalLine()

    data class Resume(override val t: Long, override val w: Long) : JournalLine()

    data class Cue(override val t: Long, override val w: Long, val kind: CueKind) : JournalLine()

    /**
     * Written first thing on resume after a process kill. [t] is the NEW monotonic time base;
     * [wallGapMs] is how long the run was dark (wall clock, clamped ≥ 0). Replay rebases the
     * timeline so run time continues across the gap and the engine sees an explicit `gaps[]` span.
     */
    data class Gap(override val t: Long, override val w: Long, val wallGapMs: Long) : JournalLine()

    /** HR link state; lets the recovery UI know whether a strap was paired. */
    data class HrLink(override val t: Long, override val w: Long, val connected: Boolean) : JournalLine()

    /**
     * `live_context` (Phase 4 §3.2, BLOCK-1): the [LiveContext] passed to `start()`, written
     * straight after the header when there is one, so `restore()` keeps comparing after a kill.
     * No line (older build, or a null context) = a silent run. Not a run event.
     */
    data class LiveContextLine(override val t: Long, override val w: Long, val context: LiveContext) : JournalLine()

    /**
     * `cue_fired`: one live compare or nudge that was spoken ([key] = board key or nudge rule,
     * [index] = km, rep or minute, [atMs] = run time of its trigger). Restore marks these done, so
     * none repeats; a point that passed while the process was dead is dropped, never spoken
     * late. Not a run event.
     */
    data class CueFired(
        override val t: Long,
        override val w: Long,
        val kind: FiredKind,
        val key: String,
        val index: Int,
        val atMs: Long,
    ) : JournalLine()

    enum class FiredKind { compare, nudge }
}
