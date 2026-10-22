package app.runsolo.core.live

import app.runsolo.core.journal.JournalLine
import app.runsolo.core.model.LiveBoard
import app.runsolo.core.model.LiveBoardKind
import app.runsolo.core.record.CueWords
import kotlin.math.abs
import kotlin.math.roundToInt
import kotlin.math.roundToLong

/**
 * The pre-run choice at Start for a Free or goal run (founder 22-Oct, "minimal first"): [chase] races the
 * runner's best on the live board and says how they stand; [steady] says no comparison at all. A run the runner
 * was not asked about (plan sessions, intervals, tests) carries no choice and speaks exactly as before.
 * [key] is the stable name stored in settings, the Pigeon `LiveContext.coachChoice` and the run file.
 */
enum class CoachChoice(val key: String) {
    chase("chase"),
    steady("steady"),
    ;

    companion object {
        /** The choice named [key]; null for none or an unknown name (a context from a newer build). */
        fun parse(key: String?): CoachChoice? = entries.firstOrNull { it.key == key }
    }
}

/** What a chase line is about. The name is its stable key in the journal's `cf` line and in the run file. */
enum class ChaseKind {
    /** Ahead of the best at this km. */
    ahead,

    /** Behind the best at this km. */
    behind,

    /** Was ahead at the last km, now behind: the "falling behind" cue. */
    slipping,

    /** Past the furthest run of this calendar month. */
    furthest,

    /** Two km to go on a distance goal. */
    last2k,
}

/** One chase line to say at [km] (whole km of the run), and what it says. */
data class ChaseCue(
    val kind: ChaseKind,
    val km: Int,
    val text: String,
    /** What to say instead when [text] would not fit the 16-word cue; null = drop it then. */
    val shortText: String? = null,
    /** True when the line carries a gap to the best (it then counts toward the cap even if said bare). */
    val withGap: Boolean = false,
)

/**
 * The comparison maths for "chase your best", pure. The base is the runner's PB itself: the board's [LiveBoard.pbSplitsMs],
 * the PB window's own cumulative time at each km (dropout-bridged by the engine, the same effort Home shows as the PB),
 * read at the same km as the live run. The window may sit mid-run (after a warm-up): the live run races its pace, not
 * its clock position, so "up on your best 5K" stays true. A PB with no usable splits, a run past the board's
 * distance or no time yet: no comparison (null), never a guess and never another run.
 */
object ChaseCompare {
    /**
     * A km faster than this (2:00/km) is not running but a GPS jump: the crossing time is not trustworthy, so no gap is
     * said off it.
     */
    const val MIN_KM_MS = 120_000L

    /** [deltaMs] = live active ms at the km minus the PB window's split there; negative = ahead. [boardKey] says which board it is read on. */
    data class Gap(val deltaMs: Long, val boardKey: String)

    /** The board's whole km (5000 m is 5; a Half's 21097.5 m is 21); null when it has no distance. */
    fun boardKm(board: LiveBoard): Int? {
        val m = board.targetM?.takeIf { it.isFinite() } ?: return null
        return (m / 1_000.0).roundToInt().takeIf { it >= 1 }
    }

    fun vsBest(board: LiveBoard, km: Int, activeMs: Long): Gap? {
        if (board.kind != LiveBoardKind.distance || activeMs <= 0) return null
        val n = boardKm(board) ?: return null
        if (km < 1 || km > n) return null
        val splits = board.pbSplitsMs ?: return null
        if (!usable(splits, n)) return null
        return Gap(activeMs - splits[km - 1], board.key)
    }

    /** True when [ms] of active time over [kms] whole km is running pace, not a jump. */
    fun plausible(kms: Int, ms: Long): Boolean = kms >= 1 && ms >= kms * MIN_KM_MS

    private fun usable(s: List<Long>, n: Int): Boolean {
        if (s.size < n || s[0] <= 0) return false
        for (i in 1 until n) if (s[i] <= s[i - 1]) return false
        return true
    }
}

/**
 * When and what the chase mode says, for one run. [choice] steady says only the plain "2 k to go" of a distance
 * goal; chase adds the gap to the best, the slip warning and the month's furthest. Pure: callers pass the figures
 * of a whole km, and the policy state only moves in [said] (a line the talk budget dropped is not counted).
 *
 * The cap keeps it from nagging: a gap line is said from km 2 (km 1 is a fast start, not news), then at most every
 * second km, and at most [MAX_GAP_LINES] a run; a flip from ahead to behind ("Slipping") or back is news and goes
 * out of turn, but still counts toward the cap, and a gap under [MIN_GAP_S] s is level and never said. One chase
 * line per km: the last-2-km line, then the furthest, then the gap.
 */
class ChaseCoach(
    val choice: CoachChoice,
    private val monthFurthestM: Double?,
    /** A distance goal's metres; null for a Free run (and for a time goal, which has no km to go). */
    private val goalDistanceM: Double?,
    fired: Collection<JournalLine.CueFired> = emptyList(),
) {
    private var gapLines = 0
    private var lastGapKm = 0
    private var furthestSaid = false
    private var last2kSaid = false

    /** The last km a line was worked out for: a km is offered once, whichever cue asks. */
    private var offeredKm = 0

    /** The side of the best at the last km a gap was seen (not only said): true = ahead; null = none yet. */
    private var lastSideAhead: Boolean? = null

    /** The board [lastSideAhead] was read on. */
    private var lastBoardKey: String? = null

    init {
        for (f in fired) {
            if (f.kind != JournalLine.FiredKind.chase) continue
            when (f.key) {
                ChaseKind.furthest.name -> furthestSaid = true
                ChaseKind.last2k.name -> {
                    last2kSaid = true
                    if (choice == CoachChoice.chase) countGap(f.index)
                }
                ChaseKind.ahead.name, ChaseKind.behind.name, ChaseKind.slipping.name -> countGap(f.index)
            }
        }
    }

    private fun countGap(km: Int) {
        gapLines++
        lastGapKm = maxOf(lastGapKm, km)
    }

    /**
     * The line to offer at whole km [km] ([activeMs] = active run ms at it), or null. [gap] is [ChaseCompare.vsBest]
     * for this km and [label] the board's spoken name ("5K"). Observing the side is the only state this changes.
     */
    fun atKm(km: Int, gap: ChaseCompare.Gap?, label: String?): ChaseCue? {
        if (km <= offeredKm) return null
        offeredKm = km
        val toGo = last2k(km)
        if (choice == CoachChoice.steady) return toGo?.let { ChaseCue(ChaseKind.last2k, km, "${it.text} to go.") }
        val side = gap?.let { sideOf(it.deltaMs) }
        // A different board (5K to 10K at km 6) is a different base: nothing "slipped", so the side starts over.
        if (gap != null && gap.boardKey != lastBoardKey) {
            lastBoardKey = gap.boardKey
            lastSideAhead = null
        }
        val flipped = side != null && lastSideAhead != null && side != lastSideAhead
        if (side != null) lastSideAhead = side
        val phrase = if (gap != null && label != null && side != null) gapPhrase(gap, side, label) else null
        if (toGo != null) {
            val bare = "${toGo.text} to go."
            return if (phrase != null && gapDue(km, flipped)) ChaseCue(ChaseKind.last2k, km, "${toGo.text} to go, $phrase", shortText = bare, withGap = true) else ChaseCue(ChaseKind.last2k, km, bare)
        }
        if (!furthestSaid && monthFurthestM != null && km * 1_000.0 > monthFurthestM) {
            return ChaseCue(ChaseKind.furthest, km, "Furthest run this month.")
        }
        if (phrase == null || !gapDue(km, flipped)) return null
        val kind = when {
            side == true -> ChaseKind.ahead
            flipped -> ChaseKind.slipping
            else -> ChaseKind.behind
        }
        return ChaseCue(kind, km, if (kind == ChaseKind.slipping) "Slipping, $phrase" else phrase)
    }

    /** [cue] was actually spoken (and is journaled): it counts toward the cap and is never offered again. */
    fun said(cue: ChaseCue) {
        when (cue.kind) {
            ChaseKind.furthest -> furthestSaid = true
            ChaseKind.last2k -> {
                last2kSaid = true
                if (cue.withGap) countGap(cue.km)
            }
            else -> countGap(cue.km)
        }
    }

    private fun gapDue(km: Int, flipped: Boolean): Boolean {
        if (km < MIN_GAP_KM || gapLines >= MAX_GAP_LINES) return false
        return flipped || gapLines == 0 || km - lastGapKm >= GAP_EVERY_KM
    }

    /** The distance to go when [km] is the first whole km with 2 500 m or less to a distance goal (4 km and up). */
    private fun last2k(km: Int): ToGo? {
        val goal = goalDistanceM ?: return null
        if (last2kSaid || goal < MIN_GOAL_M) return null
        val left = goal - km * 1_000.0
        if (left <= 0 || left > LAST_STRETCH_M) return null
        val tenths = (left / 100.0).roundToInt()
        val text = if (tenths % 10 == 0) "${tenths / 10} k" else "${tenths / 10}.${tenths % 10} k"
        return ToGo(text)
    }

    private class ToGo(val text: String)

    /** True = ahead of the best, false = behind, null = level (under [MIN_GAP_S] s: not worth a line). */
    private fun sideOf(deltaMs: Long): Boolean? {
        val s = seconds(deltaMs)
        if (s < MIN_GAP_S) return null
        return deltaMs < 0
    }

    private fun gapPhrase(gap: ChaseCompare.Gap, ahead: Boolean, label: String): String {
        val g = CueWords.gap(seconds(gap.deltaMs))
        return if (ahead) "$g up on your best $label." else "$g off your best $label."
    }

    private fun seconds(ms: Long): Long = abs(ms / 1_000.0).roundToLong()

    companion object {
        const val MIN_GAP_KM = 2
        const val GAP_EVERY_KM = 2
        const val MAX_GAP_LINES = 5
        const val MIN_GAP_S = 3L

        /** A distance goal under this has no "last 2 km" worth calling (the line would fall on km 1). */
        const val MIN_GOAL_M = 4_000.0

        /** The last-2-km line is said at the first km mark this close to the goal or closer. */
        const val LAST_STRETCH_M = 2_500.0

        /** Which chase run to take for [spec]: a Free run, or a distance goal; any other has no chase. */
        fun of(
            choice: CoachChoice?,
            freeRun: Boolean,
            goalDistanceM: Double?,
            monthFurthestM: Double?,
            fired: Collection<JournalLine.CueFired> = emptyList(),
        ): ChaseCoach? {
            if (choice == null || !(freeRun || goalDistanceM != null)) return null
            return ChaseCoach(choice, monthFurthestM?.takeIf { it.isFinite() && it > 0 }, goalDistanceM, fired)
        }
    }
}
