package app.runsolo.core.route

import app.runsolo.core.elevation.ClimbTracker
import app.runsolo.core.platform.atan2
import app.runsolo.core.platform.cos
import app.runsolo.core.platform.toRadians
import kotlin.math.abs
import kotlin.math.sqrt

/** Which way the runner is covering the old track. */
enum class RetraceDirection { reverse, same }

/**
 * What [RetraceDetector] knows right now (the Dart `RetraceState` in run_engine, field for field).
 * [distanceToStartM] is along the RECORDED track; the ahead figures are the old stretch still to
 * run; [heightVsStartM] is current minus start elevation and does not need a retrace.
 */
data class RetraceState(
    val retracing: Boolean = false,
    val direction: RetraceDirection? = null,
    val distanceToStartM: Double? = null,
    val climbAheadM: Double? = null,
    val descentAheadM: Double? = null,
    val heightVsStartM: Double? = null,
) {
    companion object {
        val NONE = RetraceState()
    }
}

/**
 * Knows when the runner is retracing a section of their own track (an out-and-back). Kotlin twin
 * of the Dart `RetraceDetector` (packages/run_engine/lib/src/engine/retrace.dart): the same rules
 * in the same order, with the shared vectors in `fixtures/retrace/vectors.json` run through both
 * (RetraceParityTest here, retrace_parity_test.dart there). Change one, change the other.
 *
 * Runs on the recorder thread so voice check-ins and the run screen read one answer with the
 * screen off. Feed it accepted fixes in order; [elevM] is any consistent elevation (only
 * differences are used).
 */
class RetraceDetector(
    val matchRadiusM: Double = 25.0,
    val sustainM: Double = 100.0,
    val gapToleranceM: Double = 30.0,
    val reverseMinGapM: Double = 40.0,
    val sameMinGapM: Double = 150.0,
    val maxHeadingDiffDeg: Double = 45.0,
) {
    // Local metres, x east / y north, about the first point.
    private var lon0 = 0.0
    private var lat0 = 0.0
    private var cosLat = 1.0
    private val xs = ArrayList<Double>()
    private val ys = ArrayList<Double>()
    private val ss = ArrayList<Double>()
    private val es = ArrayList<Double?>()
    private val segHead = ArrayList<Double>()
    private var firstElev: Double? = null
    private var lastElev: Double? = null
    private var dist0: Double? = null

    private var hasStreak = false
    private var dir: RetraceDirection? = null
    private var streakStartS = 0.0
    private var streakStartX = 0.0
    private var streakStartY = 0.0
    private var lastMatchOwnS = 0.0
    private var matchS = 0.0
    private var matchSeg = 0
    private var matchT = 0.0

    var state: RetraceState = RetraceState.NONE
        private set

    val length: Int get() = xs.size
    val trackLengthM: Double get() = if (ss.isEmpty()) 0.0 else ss.last()

    fun reset() {
        xs.clear(); ys.clear(); ss.clear(); es.clear(); segHead.clear()
        firstElev = null; lastElev = null; dist0 = null
        hasStreak = false; dir = null
        state = RetraceState.NONE
    }

    /**
     * Feeds one accepted fix. [distM] is the recorder's own filtered, pause-frozen distance run;
     * when given, along-track distances use it instead of summing raw fix-to-fix steps, which GPS
     * noise inflates (only differences are used).
     */
    fun add(lat: Double, lon: Double, elevM: Double? = null, distM: Double? = null): RetraceState {
        if (elevM != null) {
            if (firstElev == null) firstElev = elevM
            lastElev = elevM
        }
        if (xs.isEmpty()) {
            lat0 = lat
            lon0 = lon
            cosLat = cos(toRadians(lat))
        }
        val x = (lon - lon0) * M_PER_DEG * cosLat
        val y = (lat - lat0) * M_PER_DEG
        if (xs.isNotEmpty()) {
            val step = hyp(x - xs.last(), y - ys.last())
            if (step < MIN_STEP_M) {
                state = state.copy(heightVsStartM = height())
                return state
            }
            if (distM != null) {
                val d0 = dist0 ?: distM.also { dist0 = it }
                ss.add(maxOf(ss.last(), distM - d0))
            } else {
                ss.add(ss.last() + step)
            }
        } else {
            dist0 = distM
            ss.add(0.0)
        }
        xs.add(x); ys.add(y); es.add(elevM)
        update()
        return state
    }

    private fun height(): Double? {
        val a = firstElev
        val b = lastElev
        return if (a == null || b == null) null else b - a
    }

    private class Match(val distM: Double, val s: Double, val seg: Int, val t: Double, val dir: RetraceDirection)

    private fun update() {
        val here = xs.size - 1
        val sNow = ss[here]
        val head = ownHeading(here)
        var best: Match? = null
        if (head != null && here >= 2) {
            var k = 0
            while (k + 1 < here) {
                // Segments are in track order: once one is too recent for the shortest gap, all later ones are.
                if (ss[k + 1] > sNow - reverseMinGapM) break
                val (distM, t) = project(k, xs[here], ys[here])
                if (distM > matchRadiusM) { k++; continue }
                val diff = angleDiff(head, segHeading(k))
                var d: RetraceDirection? = null
                if (diff >= 180 - maxHeadingDiffDeg) {
                    d = RetraceDirection.reverse
                } else if (diff <= maxHeadingDiffDeg && ss[k + 1] <= sNow - sameMinGapM) {
                    d = RetraceDirection.same
                }
                if (d != null) {
                    val b = best
                    if (b == null || distM < b.distM) {
                        best = Match(distM, ss[k] + t * (ss[k + 1] - ss[k]), k, t, d)
                    }
                }
                k++
            }
        }
        if (best != null) {
            // The match must move along the old track the way the runner moves along the new one.
            val consistent = hasStreak && dir == best.dir &&
                (if (best.dir == RetraceDirection.reverse) best.s <= matchS + 40 else best.s >= matchS - 40)
            if (!consistent) {
                hasStreak = true
                dir = best.dir
                streakStartS = sNow
                streakStartX = xs[here]
                streakStartY = ys[here]
            }
            lastMatchOwnS = sNow
            matchS = best.s
            matchSeg = best.seg
            matchT = best.t
        } else if (hasStreak && sNow - lastMatchOwnS > gapToleranceM) {
            hasStreak = false
            dir = null
        }

        var retracing = false
        if (hasStreak) {
            val run = lastMatchOwnS - streakStartS
            val disp = hyp(xs[here] - streakStartX, ys[here] - streakStartY)
            retracing = run >= sustainM && disp >= sustainM * 0.5
        }
        if (!retracing) {
            state = RetraceState(heightVsStartM = height())
            return
        }
        val d = dir!!
        val (climb, descent) = ahead(d, here)
        state = RetraceState(
            retracing = true,
            direction = d,
            distanceToStartM = matchS,
            climbAheadM = climb,
            descentAheadM = descent,
            heightVsStartM = height(),
        )
    }

    private fun ahead(d: RetraceDirection, here: Int): Pair<Double?, Double?> {
        val series = ArrayList<Double>()
        val seg = matchSeg
        val eA = es[seg]
        val eB = es[seg + 1]
        if (eA != null && eB != null) series.add(eA + (eB - eA) * matchT)
        if (d == RetraceDirection.reverse) {
            var i = seg
            while (i >= 0) {
                es[i]?.let { series.add(it) }
                i--
            }
        } else {
            var i = seg + 1
            while (i < here && ss[i] < streakStartS) {
                es[i]?.let { series.add(it) }
                i++
            }
        }
        if (series.size < 2) return Pair(null, null)
        val t = ClimbTracker(ClimbTracker.BARO_THRESHOLD_M)
        for (e in series) t.offer(e)
        return Pair(t.ascentM, t.descentM)
    }

    private fun dist(i: Int, j: Int): Double = hyp(xs[i] - xs[j], ys[i] - ys[j])

    /** Bearing (degrees from north) of the runner's last [OWN_BASELINE_M], straight-line. */
    private fun ownHeading(here: Int): Double? {
        if (here < 1) return null
        var k = here - 1
        while (k > 0 && dist(here, k) < OWN_BASELINE_M) k--
        if (dist(here, k) < OWN_BASELINE_M / 2) return null
        return bearing(xs[k], ys[k], xs[here], ys[here])
    }

    /** Smoothed heading of old segment [k], computed once (see the Dart twin). */
    private fun segHeading(k: Int): Double {
        while (segHead.size <= k) {
            val j = segHead.size
            var a = j
            while (a > 0 && dist(j, a) < SEG_HALF_WINDOW_M) a--
            var b = j + 1
            while (b < xs.size - 1 && dist(j + 1, b) < SEG_HALF_WINDOW_M) b++
            segHead.add(bearing(xs[a], ys[a], xs[b], ys[b]))
        }
        return segHead[k]
    }

    private fun project(k: Int, px: Double, py: Double): Pair<Double, Double> {
        val ax = xs[k]
        val ay = ys[k]
        val dx = xs[k + 1] - ax
        val dy = ys[k + 1] - ay
        val len2 = dx * dx + dy * dy
        val t = if (len2 == 0.0) 0.0 else (((px - ax) * dx + (py - ay) * dy) / len2).coerceIn(0.0, 1.0)
        val cx = ax + t * dx
        val cy = ay + t * dy
        return Pair(hyp(px - cx, py - cy), t)
    }

    private fun hyp(dx: Double, dy: Double): Double = sqrt(dx * dx + dy * dy)

    private fun bearing(x0: Double, y0: Double, x1: Double, y1: Double): Double {
        val b = atan2(x1 - x0, y1 - y0) * 180 / PI
        return (b + 360) % 360
    }

    private fun angleDiff(a: Double, b: Double): Double {
        val d = abs(a - b) % 360
        return if (d > 180) 360 - d else d
    }

    companion object {
        const val MIN_STEP_M = 2.0
        private const val OWN_BASELINE_M = 30.0
        private const val SEG_HALF_WINDOW_M = 25.0
        private const val M_PER_DEG = 111_320.0
        private const val PI = 3.141592653589793
    }
}
