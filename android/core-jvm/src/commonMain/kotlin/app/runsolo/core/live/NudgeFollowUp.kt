package app.runsolo.core.live

/**
 * A nudge's own line (founder 26-Sep, plan §3.2): the cue with its compare is said as before,
 * then the nudge follows as a separate line [PAUSE_MS] after that cue is done speaking. It is
 * dropped, never queued behind other speech, when another cue is queued before it (no pile-up),
 * or when it could not start within [WINDOW_MS] of the first cue finishing. The one exception to
 * WARN-2's "an extra is never queued as a cue of its own". Times are the speaker's clock.
 */
class NudgeFollowUp {
    data class Pending(val nudge: LiveCoach.Nudge, val dueAt: Long, val deadline: Long)

    var pending: Pending? = null
        private set

    /** The cue [nudge] belongs to was queued; speech is done at [cueDoneAt]. */
    fun offer(nudge: LiveCoach.Nudge, cueDoneAt: Long) {
        pending = Pending(nudge, cueDoneAt + PAUSE_MS, cueDoneAt + WINDOW_MS)
    }

    /** Other speech was queued first: the follow-up would pile up behind it, so it goes. */
    fun cancel() {
        pending = null
    }

    /**
     * At [now], with speech busy until [busyUntil]: the nudge to say now, or null (not due yet,
     * or dropped: past the window, or something is still speaking).
     */
    fun due(now: Long, busyUntil: Long): LiveCoach.Nudge? {
        val p = pending ?: return null
        if (now < p.dueAt) return null
        pending = null
        return p.nudge.takeIf { now <= p.deadline && busyUntil <= now }
    }

    companion object {
        /** The pause between the cue and its nudge. */
        const val PAUSE_MS = 2_000L

        /** The latest a nudge may start, after the first cue is done speaking. */
        const val WINDOW_MS = 6_000L
    }
}
