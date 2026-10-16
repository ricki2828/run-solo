package app.runsolo.core.live

import app.runsolo.core.model.LiveQuest

/** What the quest beat reads at a tick; a null field = unknown, and a kind that needs it stays quiet. */
data class QuestInput(
    /** Recorder time, ms. */
    val nowMs: Long,
    val distM: Double,
    /** Barometer ascent this run, m; null without a barometer. */
    val ascentM: Double? = null,
    /** The known trail the ghost is on; null when none is matched. */
    val ghostTrailId: String? = null,
    /** Metres along that trail. */
    val alongM: Double? = null,
    /** Metres to the end of that trail. */
    val toGoM: Double? = null,
    /** Off the trail's line. */
    val off: Boolean = false,
)

/**
 * "Quest done" for the quest packed into the [app.runsolo.core.model.LiveContext] (quests spec §4): one beat per
 * run, pure. [tick] returns the line to offer the [TalkBudget] the first time the quest's threshold is crossed and
 * null from then on; the caller [spend]s it, journals it (so a restore never repeats it) and tells the screen.
 * `trail_best` is never packed: its heat factor is only final at finalise, so it completes on the result screen.
 *
 * - `climb_month`: barometer ascent reaches what is left.
 * - `distance_month`: distance reaches what is left.
 * - `trail_visits` (the last visit only): on the quest's trail, under [NEAR_END_M] from its end, not off the line.
 * - `climb_best`: on the quest's trail, the climb's top is passed, and the time between its foot and its top beat
 *   the target. A foot not seen near its start (the run joined mid-climb) never completes it.
 */
class QuestBeat(private val quest: LiveQuest, spent: Boolean = false) {
    private var spent = spent
    private var footAtMs: Long? = null
    private var footMissed = false

    /** Done, said or not: nothing more to offer this run. */
    val isSpent: Boolean get() = spent

    fun tick(i: QuestInput): TalkLine? {
        if (spent || !crossed(i)) return null
        return TalkLine(CueSlot.questDone, "questDone:${quest.id}", quest.line, holdMs = HOLD_MS)
    }

    /** The beat fired and was handled; it never fires again. */
    fun spend() {
        spent = true
    }

    /** After a restore: a climb under way is not guessed at. */
    fun resumeAt() {
        footAtMs = null
        footMissed = true
    }

    private fun crossed(i: QuestInput): Boolean = when (quest.kind) {
        LiveQuest.CLIMB_MONTH -> i.ascentM != null && quest.remaining != null && i.ascentM >= quest.remaining
        LiveQuest.DISTANCE_MONTH -> quest.remaining != null && i.distM >= quest.remaining
        LiveQuest.TRAIL_VISITS ->
            quest.remaining != null && quest.remaining <= 1.0 && i.ghostTrailId == quest.trailId &&
                i.toGoM != null && i.toGoM < NEAR_END_M && !i.off
        LiveQuest.CLIMB_BEST -> climbBeaten(i)
        else -> false
    }

    private fun climbBeaten(i: QuestInput): Boolean {
        val start = quest.climbStartM
        val end = quest.climbEndM
        val target = quest.targetMs
        val along = i.alongM
        if (start == null || end == null || target == null || along == null) return false
        if (i.ghostTrailId != quest.trailId || i.off) return false
        if (footAtMs == null && !footMissed && along >= start) {
            if (along - start <= FOOT_WINDOW_M) footAtMs = i.nowMs else footMissed = true
        }
        val foot = footAtMs ?: return false
        return along >= end && i.nowMs - foot < target
    }

    companion object {
        /**
         * How long the line waits for a gap: past the budget's 25 s minimum gap, so a quest that completes on the km
         * cue's tick is still said after it, never dropped silently. It completes once, so a late line beats none.
         */
        const val HOLD_MS = 30_000L

        /** The last trail visit counts once the runner is this close to the trail's end. */
        const val NEAR_END_M = 150.0

        /** The foot of a climb is seen when the first fix at or past it lies within this many metres of it. */
        const val FOOT_WINDOW_M = 60.0
    }
}
