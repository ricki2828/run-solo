package app.runsolo.core.trail

import app.runsolo.core.route.FollowRoute
import app.runsolo.core.route.RouteFollower
import app.runsolo.core.route.RoutePath
import app.runsolo.core.route.RouteWords
import kotlin.math.hypot
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToLong

/**
 * Recognises, early in a run, that the runner is on a trail they have run before, then says how far ahead or behind
 * their best and their last run they are at the same distance along the trail (the in-run twin of the app's
 * same-trail verdict, `trail_ghost.dart`; the two are held equal by shared vectors). Fed one accepted fix a second
 * on the recorder thread; pure and clock-free (time is the fixes' own `t` and the run's active time).
 *
 * Matching mirrors the same-trail rules on a prefix: the run must be on the trail's line ([Config.onM], the
 * `RouteMatch.coverTolM`) for [Config.confirmM] of its progress with at least [Config.minCover] of its fixes on it,
 * walking the trail's own direction (progress only moves forward, so a trail run the other way round never
 * matches). A non-loop trail is only picked up near its start; a loop or out-and-back may be joined anywhere
 * within the first [Config.engageWithinM] of the run. Several trails can look alike for a while: the first to be
 * confirmed leads, and when it is left behind the next confirmed one takes over.
 *
 * Ahead/behind is [TrailState.aheadBestMs] = the reference's time over the stretch the runner has covered minus
 * the runner's own active time since they joined, so a different start point, a shorter run or a long walk-in is
 * like for like. Positive = ahead.
 *
 * Bounded: at most [TrailRef.MAX_TRAILS] trails of [TrailRef.MAX_POINTS] vertices, a window search per fix, no
 * growth with run length.
 */
class TrailGhost(refs: List<TrailRef>, private val config: Config = Config()) {
    data class Config(
        /** The line: a fix within this of the trail is on it (`RouteMatch.coverTolM`). */
        val onM: Double = 30.0,
        val offM: Double = 40.0,
        val backM: Double = 25.0,
        val offAfterMs: Long = 10_000,
        val backAfterMs: Long = 3_000,
        val maxAccuracyM: Double = 30.0,
        val backWindowM: Double = 30.0,
        val aheadBaseM: Double = 250.0,
        val maxSpeedMps: Double = 7.0,
        val tieM: Double = 10.0,
        val gapResetMs: Long = 15_000,
        /** Start and finish of a loop sit this close (`RouteMatch.endTolM`). */
        val loopM: Double = 150.0,
        /** A non-loop trail is joined within this of its start. */
        val startZoneM: Double = 200.0,
        /** A trail is joined within this much of the run. */
        val engageWithinM: Double = 600.0,
        /** Progress along the trail before it is called a match. */
        val confirmM: Double = 300.0,
        /** Share of fixes that must be on the line (`RouteMatch.minCover`). */
        val minCover: Double = 0.8,
        /** No ahead/behind figure until the runner has covered this much of the trail. */
        val reportM: Double = 100.0,
        /** A jump along the trail over max(this, [skipFrac] of it) is ground not covered: the compare restarts from there. */
        val skipM: Double = 150.0,
        val skipFrac: Double = 0.05,
        /** Adaptive lead: clearly behind the best by more than max(this, [slipFrac] of the best's time over the stretch)... */
        val slipFloorMs: Long = 30_000,
        val slipFrac: Double = 0.03,
        /** ...for this long, and the last run is closer: race the last run. */
        val slipHoldMs: Long = 120_000,
        /** Back to the best once within [recoverFrac] of that margin for this long (the gap between the two is the hysteresis). */
        val recoverFrac: Double = 0.5,
        val recoverHoldMs: Long = 60_000,
        // The turnaround reuses the followed route's end rule (RouteFollower.Config).
        val endM: Double = 20.0,
        val endNearM: Double = 60.0,
        val endCrowM: Double = 40.0,
        val endAccuracyM: Double = 20.0,
        val endCueMs: Long = 60_000,
        val endClearM: Double = 60.0,
    )

    /** The state the run screen and the cues read; null from [state] until a trail is matched. */
    data class TrailState(
        val trailId: String,
        val name: String,
        /** Progress along the trail, metres, and how much of it is left. */
        val alongM: Double,
        val toGoM: Double,
        /** Left the line (after being matched); no figures until back on it. */
        val off: Boolean,
        /** Seconds ahead (+) or behind (-) the best run at this point, ms; null while off, too early, or beyond where that run went. */
        val aheadBestMs: Long?,
        val aheadLastMs: Long?,
        /** The last run is the best: one figure, not two. */
        val lastIsBest: Boolean,
        val bestDateMs: Long,
        val lastDateMs: Long,
        /** Metres to the turnaround point of an out-and-back trail (null once passed, or when there is none). */
        val toTurnM: Double?,
        /** Turn around cue now (see [RouteFollower.Config.endCueMs]). */
        val turnCue: Boolean,
        /** The trail's smoothed elevation at up to [PROFILE_POINTS] even steps ([elevStepM] apart) along it; null without usable elevation. */
        val elevProfile: List<Double>? = null,
        val elevStepM: Double? = null,
        /** The trail's climbs (empty when the profile was not good enough to name any). */
        val climbs: List<TrailClimb> = emptyList(),
        /** Metres to the start of the next climb ahead; null when none is ahead or the runner is on one. */
        val toClimbM: Double? = null,
        val inClimb: Boolean = false,
        /** Which run leads the figure: `best` to start with, `last` once the runner has slipped clearly behind the best and the last is closer. */
        val racing: Racing = Racing.best,
    )

    enum class Racing { best, last }

    /** The lead figure changed hands at [t]: [toLast] true = now racing the last run, false = back to the best. */
    data class Switch(val t: Long, val trailId: String, val toLast: Boolean)


    private inner class Cand(val ref: TrailRef) {
        val path = RoutePath(FollowRoute(ref.id, ref.name, ref.latLon))
        val loopish = path.closesOnStart(config.loopM)
        val apex: Pair<Double, Double>? = ref.turnAlongM?.takeIf { it < path.totalM }?.let { path.pointAt(it) }
        val elev: List<Double>? = ref.elevation
        val climbs: List<TrailClimb> = ref.sensibleClimbs
        val elevProfile: List<Double>? = elev?.let { runCatching { sampleEvenly(path, it) }.getOrNull() }
        var dead = false
        var engaged = false
        var confirmed = false
        var off = false
        var a0 = 0.0
        var along = 0.0
        var myT0 = 0L
        var n = 0
        var onN = 0
        var sumOff = 0.0
        var offSince: Long? = null
        var backSince: Long? = null
        var lastOnT: Long? = null
        var lastFixT: Long? = null
        var racingLast = false
        var behindSince: Long? = null
        var calmSince: Long? = null
        var rebaseAt = Long.MIN_VALUE / 2
        var turnFired = false
        var turnT = 0L
        var crowToApexM = Double.MAX_VALUE

        val meanOffM: Double get() = if (onN == 0) Double.MAX_VALUE else sumOff / onN

        fun step(t: Long, lat: Double, lon: Double, accuracyM: Double, activeMs: Long, runDistM: Double) {
            val x = path.toLocalX(lon)
            val y = path.toLocalY(lat)
            val prev = lastFixT
            lastFixT = t
            val sinceFix = if (prev == null) 0L else (t - prev).coerceAtLeast(0)
            if (sinceFix > config.gapResetMs) {
                offSince = null
                backSince = null
            }
            val onLimit = max(config.onM, accuracyM * 1.5)
            if (!engaged) {
                if (runDistM > config.engageWithinM) {
                    dead = true
                    return
                }
                val hit = if (loopish) path.nearest(x, y, 0.0, path.totalM, config.tieM)
                else path.nearest(x, y, 0.0, min(path.totalM, config.startZoneM), config.tieM)
                if (hit != null && hit.offM <= onLimit) {
                    engaged = true
                    a0 = hit.alongM
                    along = hit.alongM
                    myT0 = activeMs
                    lastOnT = t
                    n = 1
                    onN = 1
                    sumOff = hit.offM
                }
                return
            }
            val sinceOn = lastOnT?.let { (t - it).coerceAtLeast(0) } ?: 0L
            val away = max(sinceFix, if (off || offSince != null) sinceOn else 0L)
            val reach = config.aheadBaseM + config.maxSpeedMps * away / 1000.0
            val hit = path.nearest(x, y, max(0.0, along - config.backWindowM), min(path.totalM, along + reach), config.tieM)
            val dist = hit?.offM ?: Double.MAX_VALUE
            n++
            if (dist <= onLimit) {
                onN++
                sumOff += dist
            }
            val offLimit = max(config.offM, accuracyM * 1.5)
            val backLimit = max(config.backM, accuracyM)
            if (!off) {
                if (hit == null || dist > offLimit) {
                    val since = offSince ?: t.also { offSince = it }
                    if (t - since >= config.offAfterMs) {
                        if (confirmed) {
                            off = true
                            offSince = null
                            backSince = null
                        } else if (runDistM <= config.engageWithinM) {
                            // Still in the first stretch and not yet sure: a warm-up wobble (or the car park) is not the end of the
                            // trail. Look for the line again from scratch.
                            engaged = false
                            offSince = null
                            backSince = null
                            n = 0
                            onN = 0
                            sumOff = 0.0
                            return
                        } else {
                            dead = true
                            return
                        }
                    }
                } else {
                    offSince = null
                    lastOnT = t
                    advance(hit.alongM, activeMs)
                }
            } else if (hit != null && dist <= backLimit) {
                val since = backSince ?: t.also { backSince = it }
                if (t - since >= config.backAfterMs) {
                    off = false
                    backSince = null
                    offSince = null
                    lastOnT = t
                    advance(hit.alongM, activeMs)
                }
            } else {
                backSince = null
            }
            if (!confirmed && along - a0 >= config.confirmM && onN >= config.minCover * n) confirmed = true
            apex?.let { crowToApexM = hypot(x - it.first, y - it.second) }
        }

        /**
         * Progress only moves forward. A jump further than [skipM] is ground the runner did not cover (a shortcut, a
         * long fix gap): the comparison starts over from the re-matched point, so a skipped section never reads as
         * time gained.
         */
        private fun advance(alongM: Double, activeMs: Long) {
            if (alongM <= along) return
            if (alongM - along > max(config.skipM, config.skipFrac * path.totalM)) {
                a0 = alongM
                myT0 = activeMs
                rebaseAt = activeMs
            }
            along = alongM
        }
    }

    // One trail that cannot be set up (or later throws on a fix) is dropped alone: the others keep matching.
    private val cands: List<Cand> = refs.take(TrailRef.MAX_TRAILS).mapNotNull { r -> runCatching { Cand(r) }.getOrNull() }
    private var leader: Cand? = null

    /** The matched trail's state after the last fix; null until one is confirmed. */
    var state: TrailState? = null
        private set

    /** Ids of the trails still in the running (not ruled out), for the audit and the tests. */
    val candidateIds: List<String> get() = cands.filter { !it.dead }.map { it.ref.id }

    /**
     * Takes one fix. [activeMs] is the run's active (moving) time at this fix and [runDistM] its distance so far.
     * Returns the turnaround event, at most once per trail. A fix worse than [Config.maxAccuracyM] changes nothing.
     */
    fun offer(t: Long, lat: Double, lon: Double, accuracyM: Double, activeMs: Long, runDistM: Double): List<RouteFollower.Event> {
        if (!lat.isFinite() || !lon.isFinite() || !accuracyM.isFinite() || accuracyM > config.maxAccuracyM) return emptyList()
        for (c in cands) if (!c.dead) {
            try {
                c.step(t, lat, lon, accuracyM, activeMs, runDistM)
            } catch (e: Exception) {
                c.dead = true
            }
        }
        val cur = leader
        if (cur == null || cur.off) {
            val next = cands.filter { it.confirmed && !it.dead && !it.off }.minByOrNull { it.meanOffM }
            if (next != null) leader = next
        }
        val lead = leader
        if (lead == null) {
            state = null
            return emptyList()
        }
        val events = ArrayList<RouteFollower.Event>(1)
        val ref = lead.ref
        val turn = ref.turnAlongM
        if (turn != null && lead.apex != null && !lead.off && !lead.turnFired && lead.a0 < turn - config.endNearM && accuracyM <= config.endAccuracyM) {
            val toApex = turn - lead.along
            if (toApex <= config.endM || (toApex <= config.endNearM && lead.crowToApexM <= max(config.endCrowM, accuracyM * 1.5))) {
                lead.turnFired = true
                lead.turnT = t
                events.add(RouteFollower.Event.RouteEnd(t, RouteFollower.EndKind.turnAround, RouteWords.END_TURN_AROUND))
            }
        }
        state = stateOf(lead, t, activeMs)
        return events
    }

    private fun stateOf(c: Cand, t: Long, activeMs: Long): TrailState {
        val ref = c.ref
        val reported = !c.off && c.along - c.a0 >= config.reportM
        fun ahead(p: TrailProfile): Long? {
            if (!reported) return null
            val at = c.path.interpolate(c.along, p.ms) ?: return null
            val from = c.path.interpolate(c.a0, p.ms) ?: return null
            return ((at - from) - (activeMs - c.myT0)).roundToLong()
        }
        val last = ref.last ?: ref.best
        val turn = ref.turnAlongM
        val aBest = ahead(ref.best)
        val aLast = if (ref.last == null) aBest else ahead(last)
        adapt(c, t, activeMs, aBest, aLast, ref)
        val onClimb = c.climbs.any { c.along >= it.startM && c.along <= it.endM }
        val nextClimb = if (onClimb) null else c.climbs.firstOrNull { it.startM > c.along }
        return TrailState(
            trailId = ref.id,
            name = ref.name,
            alongM = c.along,
            toGoM = max(0.0, c.path.totalM - c.along),
            off = c.off,
            aheadBestMs = aBest,
            aheadLastMs = aLast,
            lastIsBest = ref.last == null,
            bestDateMs = ref.best.dateMs,
            lastDateMs = last.dateMs,
            toTurnM = if (turn != null && !c.turnFired && c.along < turn) turn - c.along else null,
            turnCue = c.turnFired && t - c.turnT < config.endCueMs && c.crowToApexM <= config.endClearM,
            elevProfile = c.elevProfile,
            elevStepM = c.elevProfile?.let { c.path.totalM / (it.size - 1) },
            climbs = c.climbs,
            toClimbM = nextClimb?.let { it.startM - c.along },
            inClimb = onClimb,
            racing = if (c.racingLast) Racing.last else Racing.best,
        )
    }

    private val switches = ArrayList<Switch>(2)

    /** The lead changes since the last call, oldest first; at most a couple are ever waiting. */
    fun drainSwitches(): List<Switch> {
        if (switches.isEmpty()) return emptyList()
        val out = ArrayList(switches)
        switches.clear()
        return out
    }

    /**
     * Start against the best; when clearly behind it for a while and the last run is closer, race the last; back to the
     * best on recovery. The enter margin is max(floor, 3% of the best's time over the stretch run), the exit margin half
     * of it, each held for a time, so it cannot flap. A figure that is missing (off the line, too early) pauses both timers.
     */
    private fun adapt(c: Cand, t: Long, now: Long, aBest: Long?, aLast: Long?, ref: TrailRef) {
        if (ref.last == null || aBest == null || aLast == null) {
            c.behindSince = null
            c.calmSince = null
            return
        }
        val stretch = c.path.interpolate(c.along, ref.best.ms)?.let { at -> c.path.interpolate(c.a0, ref.best.ms)?.let { at - it } } ?: 0.0
        val margin = max(config.slipFloorMs.toDouble(), config.slipFrac * stretch)
        if (!c.racingLast) {
            if (aBest < -margin && aLast > aBest) {
                val since = c.behindSince ?: now.also { c.behindSince = it }
                if (now - since >= config.slipHoldMs) {
                    c.racingLast = true
                    c.behindSince = null
                    c.calmSince = null
                    if (switches.size < 4) switches.add(Switch(t, ref.id, true))
                }
            } else c.behindSince = null
        } else {
            // Right after a skipped section the compare restarts from near zero: that is not a recovery.
            if (aBest >= -margin * config.recoverFrac && now - c.rebaseAt >= config.recoverHoldMs) {
                val since = c.calmSince ?: now.also { c.calmSince = it }
                if (now - since >= config.recoverHoldMs) {
                    c.racingLast = false
                    c.calmSince = null
                    c.behindSince = null
                    if (switches.size < 4) switches.add(Switch(t, ref.id, false))
                }
            } else c.calmSince = null
        }
    }

    companion object {
        /** The most points of the elevation profile sent on the event bus each tick. */
        const val PROFILE_POINTS = 48

        /** [elev] (one per vertex of [path]) sampled at [PROFILE_POINTS] even steps along the whole trail, 1 dp. */
        internal fun sampleEvenly(path: RoutePath, elev: List<Double>): List<Double> {
            val n = PROFILE_POINTS
            val out = ArrayList<Double>(n)
            var seg = 0
            for (k in 0 until n) {
                val a = path.totalM * k / (n - 1)
                while (seg < path.size - 2 && path.cum[seg + 1] < a) seg++
                val len = path.cum[seg + 1] - path.cum[seg]
                val f = if (len > 0) ((a - path.cum[seg]) / len).coerceIn(0.0, 1.0) else 0.0
                val v = elev[seg] + (elev[seg + 1] - elev[seg]) * f
                out.add(kotlin.math.round(v * 10) / 10)
            }
            return out
        }
    }
}
