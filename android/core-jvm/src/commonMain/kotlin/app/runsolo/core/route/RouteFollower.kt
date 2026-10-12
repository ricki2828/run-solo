package app.runsolo.core.route

import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt

/**
 * Where the runner is on a followed route, and whether they have left it (Follow a route). Fed one accepted
 * fix a second by the recording session, on the recorder thread, so it works with the screen off. Pure and
 * clock-free: time is the fixes' own `t`, so a replay and a test drive it identically.
 *
 * Progress along the route only ever moves forward. Each fix is matched to the route inside a window that starts
 * just behind the last progress and reaches ahead as far as a runner could have gone since the last fix and the
 * last time they were on the line, so an out-and-back or a loop that closes on its start follows the route's
 * order, not the nearest line in the plan.
 *
 * Off route = further than [Config.offM] (widened for a poor fix) for [Config.offAfterMs] without a break;
 * back on route = within [Config.backM] for [Config.backAfterMs]. The gap between the two is the hysteresis.
 */
class RouteFollower(
    val path: RoutePath,
    private val config: Config = Config(),
    /** Miles users hear and read yards, not metres, for a turn ahead. */
    private val imperial: Boolean = false,
) {
    data class Config(
        val offM: Double = 40.0,
        val backM: Double = 25.0,
        val offAfterMs: Long = 10_000,
        val backAfterMs: Long = 3_000,
        /** A fix worse than this says nothing about being on or off the route. */
        val maxAccuracyM: Double = 30.0,
        /** How far behind the last progress a fix may still match (GPS jitter at a standstill, a step back). */
        val backWindowM: Double = 30.0,
        val aheadBaseM: Double = 250.0,
        /** The fastest the runner is credited with when widening the window after time away. */
        val maxSpeedMps: Double = 7.0,
        val tieM: Double = 10.0,
        /** A silence this long forgets a half-built off/back streak. */
        val gapResetMs: Long = 15_000,
        val turnAnnounceM: Double = 50.0,
        /** Off route still: the alert again after this long. */
        val repeatOffMs: Long = 60_000,
        /** The end of the route is reached when this little is left (a trail finish is rarely on the exact point). */
        val endM: Double = 20.0,
        /** A fix worse than this does not announce the end: it could be tens of metres short or past it. */
        val endAccuracyM: Double = 20.0,
        /** A route shorter than this has no end worth a cue. */
        val minEndRouteM: Double = 100.0,
        /** A route that finishes this close to its start is a loop: "Route done", not "Turn around". */
        val loopM: Double = 50.0,
        /** The screen's turn-around cue stays up this long after the end... */
        val endCueMs: Long = 60_000,
        /** ...or until the runner is this far from the end (heading back). */
        val endClearM: Double = 60.0,
    )

    /** What the end of the route means: an out-and-back or point-to-point end says turn around, a loop is simply done. */
    enum class EndKind { turnAround, done }

    /** What the follower wants said or buzzed. */
    sealed class Event {
        data class OffRoute(val t: Long) : Event()
        data class BackOnRoute(val t: Long) : Event()

        /** An approaching turn, [text] as the voice says it. */
        data class Turn(val t: Long, val turn: RouteTurn, val text: String) : Event()

        /** The runner reached the end of the route, once. [kind] says whether to turn around or that the route is done. */
        data class RouteEnd(val t: Long, val kind: EndKind, val text: String) : Event()
    }

    var progressM: Double = 0.0
        private set
    var off: Boolean = false
        private set

    /** Distance from the line at the last accepted fix. */
    var offsetM: Double = 0.0
        private set

    val toGoM: Double get() = max(0.0, path.totalM - progressM)
    val climbToGoM: Double? get() = path.climbToGoM(progressM)

    /**
     * When the current (or last) excursion really began: the first fix beyond the off-route limit of the streak
     * that tripped the alert, which is [Config.offAfterMs] before the alert. For totals that are not short.
     */
    var offBeganT: Long? = null
        private set

    /** When the runner was first back within the on-route limit, [Config.backAfterMs] before "back on route". */
    var backBeganT: Long? = null
        private set

    private var lastOnT: Long? = null
    private var lastFixT: Long? = null
    private var offSinceT: Long? = null
    private var backSinceT: Long? = null
    private var lastAlertT = 0L
    private var turnIndex = 0
    private var turnToldIndex = -1
    private var ended = false
    private var endT: Long? = null
    private var distToEndM = Double.MAX_VALUE
    private val endKind = if (path.closesOnStart(config.loopM)) EndKind.done else EndKind.turnAround

    /** The end-of-route cue the screen shows now, or null: it lapses after [Config.endCueMs] or once the runner is [Config.endClearM] back along the way. */
    val endCue: EndKind?
        get() {
            val at = endT ?: return null
            val now = lastFixT ?: return null
            return if (ended && now - at < config.endCueMs && distToEndM <= config.endClearM) endKind else null
        }

    /** The next turn still ahead (the cue for it may already have been said). */
    val nextTurn: RouteTurn? get() = path.turns.getOrNull(turnIndex)

    /** Metres to [nextTurn]; null when there is none or the runner is off the line (the shape no longer applies). */
    val nextTurnInM: Double? get() = if (off) null else nextTurn?.let { max(0.0, it.atM - progressM) }

    /**
     * Takes one fix; returns what to say. A fix worse than [Config.maxAccuracyM] changes nothing. [quiet]
     * rebuilds the state (a resume from the journal) and returns nothing.
     */
    fun offer(t: Long, lat: Double, lon: Double, accuracyM: Double, quiet: Boolean = false): List<Event> {
        if (!lat.isFinite() || !lon.isFinite() || !accuracyM.isFinite() || accuracyM > config.maxAccuracyM) return emptyList()
        val prevFix = lastFixT
        lastFixT = t
        val sinceFix = if (prevFix == null) 0L else (t - prevFix).coerceAtLeast(0)
        if (ended) {
            // The route is done: nothing more to follow, so no off-route alerts for the way back.
            distToEndM = path.distToEndM(path.toLocalX(lon), path.toLocalY(lat))
            return emptyList()
        }
        if (sinceFix > config.gapResetMs) {
            offSinceT = null
            backSinceT = null
        }
        val sinceOn = lastOnT?.let { (t - it).coerceAtLeast(0) } ?: 0L
        val away = max(sinceFix, if (off || offSinceT != null) sinceOn else 0L)
        val reach = config.aheadBaseM + config.maxSpeedMps * away / 1000.0
        val hit = path.nearest(
            path.toLocalX(lon), path.toLocalY(lat),
            max(0.0, progressM - config.backWindowM), min(path.totalM, progressM + reach), config.tieM,
        )
        // Nothing in the window at all (the run is somewhere the route never goes): as far off as it gets.
        val dist = hit?.offM ?: Double.MAX_VALUE
        offsetM = dist
        val events = ArrayList<Event>()
        // A poor fix may sit a few metres out without the runner having moved.
        val offLimit = max(config.offM, accuracyM * 1.5)
        val backLimit = max(config.backM, accuracyM)
        if (!off) {
            if (hit == null || dist > offLimit) {
                val since = offSinceT ?: t.also { offSinceT = it }
                if (t - since >= config.offAfterMs) {
                    off = true
                    offBeganT = since
                    offSinceT = null
                    backSinceT = null
                    lastAlertT = t
                    events.add(Event.OffRoute(t))
                }
            } else {
                offSinceT = null
                lastOnT = t
                advance(hit)
                turnEvent(t)?.let { events.add(it) }
                endEvent(t, accuracyM, lat, lon, quiet)?.let { events.add(it) }
            }
        } else if (hit != null && dist <= backLimit) {
            val since = backSinceT ?: t.also { backSinceT = it }
            if (t - since >= config.backAfterMs) {
                off = false
                backBeganT = since
                backSinceT = null
                offSinceT = null
                lastOnT = t
                advance(hit)
                events.add(Event.BackOnRoute(t))
            }
        } else {
            backSinceT = null
            if (t - lastAlertT >= config.repeatOffMs) {
                lastAlertT = t
                events.add(Event.OffRoute(t))
            }
        }
        return if (quiet) emptyList() else events
    }

    /** After a restore the fixes' clock is a new one: forget the old streaks and gaps (progress and off-route state stay). */
    fun restartClock() {
        lastOnT = null
        lastFixT = null
        offSinceT = null
        backSinceT = null
        endT = null // a restored run does not re-show the cue
    }

    /** Once, when the runner is within [Config.endM] of the end on a good fix. A restore (quiet) marks the end as reached with no cue. */
    private fun endEvent(t: Long, accuracyM: Double, lat: Double, lon: Double, quiet: Boolean): Event.RouteEnd? {
        if (path.totalM < config.minEndRouteM || toGoM > config.endM || accuracyM > config.endAccuracyM) return null
        ended = true
        distToEndM = path.distToEndM(path.toLocalX(lon), path.toLocalY(lat))
        if (quiet) return null
        endT = t
        return Event.RouteEnd(t, endKind, if (endKind == EndKind.done) RouteWords.END_DONE else RouteWords.END_TURN_AROUND)
    }

    private fun advance(hit: RouteHit) {
        if (hit.alongM > progressM) progressM = hit.alongM
        // Turns behind the runner are done with.
        while (turnIndex < path.turns.size && path.turns[turnIndex].atM <= progressM) turnIndex++
    }

    /** The cue for the next turn, once, when it comes within [Config.turnAnnounceM] (never when first seen already on top of it). */
    private fun turnEvent(t: Long): Event.Turn? {
        val turn = path.turns.getOrNull(turnIndex) ?: return null
        if (turnToldIndex == turnIndex) return null
        val ahead = turn.atM - progressM
        if (ahead > config.turnAnnounceM) return null
        turnToldIndex = turnIndex
        if (ahead < MIN_WARNING_M) return null
        return Event.Turn(t, turn, RouteWords.turnCue(turn, ahead, imperial))
    }

    companion object {
        /** A turn first noticed closer than this is not announced: it would be said as the runner is in it. */
        const val MIN_WARNING_M = 15.0

        /** Whole 10 m for the voice, never below 10. */
        fun roundedAheadM(metres: Double): Int = max(10, (metres / 10).roundToInt() * 10)
    }
}

/** What the route's cues say (JVM-tested wording, spoken through the session's cue player). */
object RouteWords {
    const val OFF_ROUTE = "Off route"
    const val BACK_ON_ROUTE = "Back on route"
    const val END_TURN_AROUND = "End of route. Turn around."
    const val END_DONE = "End of route. Route done."

    /** "Left turn", "Keep right", "Sharp left", "U-turn": the label the strip shows (with the distance) and the voice says. */
    fun turnLabel(turn: RouteTurn): String = when (turn.kind) {
        TurnKind.keep -> if (turn.right) "Keep right" else "Keep left"
        TurnKind.turn -> if (turn.right) "Right turn" else "Left turn"
        TurnKind.sharp -> if (turn.right) "Sharp right" else "Sharp left"
        TurnKind.uTurn -> "U-turn"
    }

    private const val YARDS_PER_METRE = 1.09361

    /** "50 m", or "50 yd" for miles users: whole 10s, never below 10. */
    fun aheadText(aheadM: Double, imperial: Boolean): String =
        if (imperial) "${RouteFollower.roundedAheadM(aheadM * YARDS_PER_METRE)} yd" else "${RouteFollower.roundedAheadM(aheadM)} m"

    /** "Left turn in 50 m"; a "keep" is a nudge, said with no distance. */
    fun turnCue(turn: RouteTurn, aheadM: Double, imperial: Boolean = false): String =
        if (turn.kind == TurnKind.keep) turnLabel(turn) else "${turnLabel(turn)} in ${aheadText(aheadM, imperial)}"
}
