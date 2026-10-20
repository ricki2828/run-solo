package app.runsolo.core.live

import app.runsolo.core.record.CueWords

/**
 * "Halfway." and "5 minutes to go." for a plan easy or long run, on the planned minutes the app
 * carried in `VoiceCoachConfig` (the run itself stays a Free run: no duration step, not a goal).
 *
 * Time is the recorder's ACTIVE time (`Status.activeMs`: moving, pauses and auto-pauses excluded),
 * the time plan completion scores, so a stop at the lights never brings a cue forward or drops it. Halfway only when planned is [HALFWAY_MIN_MINUTES] or
 * more, at planned / 2; 5 to go only when planned is [TO_GO_MIN_MINUTES] or more. Nothing at or
 * past the planned time. Each line is said once: a cue that falls while speech is still queued
 * (a km line) waits for it, and one more than [LATE_MS] late (a pause, a long km line) is dropped
 * rather than said at the wrong moment. [restoredAt] marks what had already passed, so a resume
 * never re-fires; the flags are rebuilt from the clock, so nothing extra is persisted.
 */
class PlannedTimeCues(kind: String?, minutes: Int?) {
    private val plannedMs: Long =
        if ((kind == KIND_EASY || kind == KIND_LONG) && minutes != null && minutes > 0) minutes * 60_000L else 0L

    private class Cue(val atMs: Long, val text: String, var done: Boolean = false)

    private val cues: List<Cue> = buildList {
        val planned = (plannedMs / 60_000L).toInt()
        if (planned >= HALFWAY_MIN_MINUTES) add(Cue(plannedMs / 2, CueWords.PLANNED_HALFWAY))
        if (planned >= TO_GO_MIN_MINUTES) add(Cue(plannedMs - TO_GO_MS, CueWords.plannedToGo((TO_GO_MS / 60_000L).toInt())))
    }.sortedBy { it.atMs }

    /** True when this run has any planned-time line to say. */
    val active: Boolean get() = cues.isNotEmpty()

    /** A resume after a kill: every cue already due at [activeMs] is done, never said again. */
    fun restoredAt(activeMs: Long) {
        for (c in cues) if (activeMs >= c.atMs) c.done = true
    }

    /**
     * One tick while recording. [activeMs] is the active time, [t] the session clock and
     * [busyUntil] when queued speech ends on it. Returns the line to say now, or null.
     */
    fun tick(activeMs: Long, t: Long, busyUntil: Long): String? {
        if (plannedMs == 0L || activeMs >= plannedMs) return null
        for (c in cues) {
            if (c.done || activeMs < c.atMs) continue
            if (activeMs - c.atMs > LATE_MS) {
                c.done = true
                continue
            }
            if (busyUntil > t) return null // queue behind the line being said
            c.done = true
            return c.text
        }
        return null
    }

    companion object {
        const val KIND_EASY = "easy"
        const val KIND_LONG = "long"
        const val HALFWAY_MIN_MINUTES = 20
        const val TO_GO_MIN_MINUTES = 15
        const val TO_GO_MS = 5 * 60_000L

        /** A cue this far past its moment is dropped, not said late. */
        const val LATE_MS = 20_000L
    }
}
