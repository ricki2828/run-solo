package app.runsolo.core.live

import app.runsolo.core.record.CueWords
import kotlin.math.abs
import kotlin.math.roundToInt

/** What a trail moment needs at a tick; a null field = unknown, and the moments that read it stay quiet. */
data class MomentInput(
    val nowMs: Long,
    val distM: Double,
    /** Metres of climbing left on the old track ahead (retrace), null when not retracing. */
    val climbAheadM: Double? = null,
    /** Barometer ascent this run, m; null without a barometer. */
    val ascentM: Double? = null,
    /** Live grade as a fraction (0.05 = 5%); null = unknown. */
    val grade: Double? = null,
    /** Trail ghost: seconds ahead of the best (negative = behind); null until the ghost stream lands. */
    val ghostAheadSec: Double? = null,
    /** Trail ghost: metres to the end of a known trail; null on an unknown trail. */
    val toEndM: Double? = null,
    /** Trail ghost: the figure above is against the last run (the runner slipped behind the best), not the best. */
    val racingLast: Boolean = false,
    /** Trail ghost: the next known climb within call-out range (where it starts along the trail and what it gains); null = none. */
    val knownClimbStartM: Double? = null,
    val knownClimbGainM: Double? = null,
)

/**
 * The trail's event beats for [TalkBudget] (cadence v1 §3: E3 climb ahead, E4 climb done, E5 ghost flip, E8 final
 * push). Hooks, not data: the ghost fields are null until the ghost engine fills [MomentInput], so with none the
 * ghost beats are silent and the climb beats run on what the barometer and the retrace detector already know.
 * The turnaround and the finish verdict come from the ghost engine and the stop path; they are offered through
 * [app.runsolo.record.CuePlayer.moment] directly. One per run; pure.
 */
class TrailMoments {
    private var gate = AheadBehindGate()
    private var switchId = 0
    private val knownClimbsSaid = HashSet<Int>()
    private var climbAheadAtM = Double.NEGATIVE_INFINITY
    private var climbId = 0
    private var climbStartAscent: Double? = null
    private var flatSinceM: Double? = null
    private var finalPushSaid = false

    fun tick(i: MomentInput): List<TalkLine> {
        val out = ArrayList<TalkLine>(2)
        climbAhead(i)?.let { out += it }
        knownClimb(i)?.let { out += it }
        climbDone(i)?.let { out += it }
        flip(i)?.let { out += it }
        finalPush(i)?.let { out += it }
        return out
    }

    /** After a restore: what was passed while dead is not said late, and a climb under way is not guessed at. */
    fun resumeAt(distM: Double) {
        climbAheadAtM = distM
        climbStartAscent = null
        flatSinceM = null
    }

    /**
     * A climb of the known trail, called out once each from its own key (so two climbs on one trail are both said, and
     * neither waits on the retrace rule's 1 km repeat gap): "Climb ahead. 40 metres up."
     */
    private fun knownClimb(i: MomentInput): TalkLine? {
        val start = i.knownClimbStartM ?: return null
        val gain = i.knownClimbGainM?.takeIf { it >= MIN_CLIMB_M } ?: return null
        val id = start.roundToInt()
        if (!knownClimbsSaid.add(id)) return null
        return TalkLine(CueSlot.climbAhead, "climbAhead:known:$id", "Climb ahead. ${CheckInWords.metres(gain)} up.")
    }

    /** The lead moved to another known trail: its gap is another reference, so the flip gate starts over. Nothing is said. */
    fun leaderChanged() {
        gate = AheadBehindGate()
    }

    private fun climbAhead(i: MomentInput): TalkLine? {
        val c = i.climbAheadM?.takeIf { it >= MIN_CLIMB_M } ?: return null
        if (i.distM - climbAheadAtM < CLIMB_AHEAD_REPEAT_M) return null
        climbAheadAtM = i.distM
        // The retrace figure is the climb left on the way back in total, not one slope: say so. One key and the metres left as its value: the budget says it again only once that has moved 40 m, so the way back
        // does not repeat the same number every km, barometer or not.
        return TalkLine(CueSlot.climbAhead, "climbAhead", "Climb ahead. ${CheckInWords.metres(c)} of climbing left.", c, CLIMB_STEP_M)
    }

    /** The top of a climb: 30 m of gain, then the grade stays under 2% for 100 m. */
    private fun climbDone(i: MomentInput): TalkLine? {
        val asc = i.ascentM ?: return null
        val g = i.grade ?: return null
        val start = climbStartAscent
        if (start == null) {
            if (g >= CLIMB_GRADE) climbStartAscent = asc
            return null
        }
        if (g >= FLAT_GRADE) {
            flatSinceM = null
            return null
        }
        val since = flatSinceM ?: i.distM.also { flatSinceM = it }
        if (i.distM - since < FLAT_HOLD_M) return null
        val gain = asc - start
        climbStartAscent = null
        flatSinceM = null
        if (gain < MIN_CLIMB_M) return null
        val id = climbId++
        return TalkLine(CueSlot.climbDone, "climbDone:$id", "Climb done. ${CheckInWords.metres(gain)} up.")
    }

    private fun flip(i: MomentInput): TalkLine? {
        val g = i.ghostAheadSec ?: return null
        val side = gate.update(i.nowMs, i.distM, g) ?: return null
        val who = if (i.racingLast) "last run" else "best"
        return TalkLine(CueSlot.ghostFlip, "ghostFlip:${i.distM.roundToInt()}", if (side > 0) "Ahead of your $who now." else "Your $who just passed you.")
    }

    /**
     * The ghost changed who it races: the best to start with, the last run once the runner has slipped clearly behind
     * the best and the last is closer, and back. One line, and the ahead/behind gate starts over: a gap against the
     * other run is not a flip.
     */
    fun switched(toLast: Boolean): TalkLine {
        gate = AheadBehindGate()
        return TalkLine(
            CueSlot.ghostFlip,
            "ghostSwitch:${switchId++}",
            if (toLast) "Racing your last run now." else "Back to racing your best.",
        )
    }

    private fun finalPush(i: MomentInput): TalkLine? {
        val g = i.ghostAheadSec ?: return null
        val left = i.toEndM ?: return null
        if (finalPushSaid || left > FINAL_PUSH_M || left < FINAL_PUSH_M / 2) return null
        if (g > 0 || g < -FINAL_PUSH_WITHIN_SEC) return null
        finalPushSaid = true
        return TalkLine(CueSlot.finalPush, "finalPush", "One k left. ${CueWords.gap(abs(g).roundToInt().toLong())} to find for your ${if (i.racingLast) "last run" else "best"}.")
    }

    companion object {
        const val MIN_CLIMB_M = 30.0
        const val CLIMB_GRADE = 0.05
        const val FLAT_GRADE = 0.02
        const val FLAT_HOLD_M = 100.0
        const val CLIMB_STEP_M = 40.0
        const val CLIMB_AHEAD_REPEAT_M = 1_000.0
        const val FINAL_PUSH_M = 1_000.0
        const val FINAL_PUSH_WITHIN_SEC = 30.0
    }
}
