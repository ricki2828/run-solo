package app.runsolo.core.route

import app.runsolo.core.elevation.ClimbTracker
import app.runsolo.core.platform.atan2
import app.runsolo.core.platform.cos
import app.runsolo.core.platform.toRadians
import kotlin.math.abs
import kotlin.math.floor
import kotlin.math.max
import kotlin.math.min
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

/** A growable DoubleArray: no boxing per point on a long run. */
private class DoubleList {
    var a = DoubleArray(256)
    var size = 0
    fun add(v: Double) {
        if (size == a.size) a = a.copyOf(size * 2)
        a[size++] = v
    }
    operator fun get(i: Int): Double = a[i]
    fun clear() { size = 0 }
    fun last(): Double = a[size - 1]
}

/** A growable IntArray for the spatial index's cell lists. */
private class IntList {
    var a = IntArray(8)
    var size = 0
    fun add(v: Int) {
        if (size == a.size) a = a.copyOf(size * 2)
        a[size++] = v
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
 * differences are used). A tick costs a lookup in a 50 m cell index, not a scan of the track, and
 * allocates nothing but the state it returns.
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
    private val xs = DoubleList()
    private val ys = DoubleList()
    private val ss = DoubleList()

    /** Elevation per point, NaN for none. */
    private val es = DoubleList()
    private val segHead = DoubleList()

    /** Cell -> the segments whose box, grown by the match radius, touches it (in track order). */
    private val grid = HashMap<Long, IntList>()
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
    private var streakId = 0

    // Cached climb/descent ahead.
    private var aheadStreak = -1
    private var aheadAtS = 0.0
    private var aheadClimb: Double? = null
    private var aheadDescent: Double? = null

    // The result of one project() call (fields, so a search allocates nothing).
    private var projDist = 0.0
    private var projT = 0.0

    var state: RetraceState = RetraceState.NONE
        private set

    val length: Int get() = xs.size
    val trackLengthM: Double get() = if (ss.size == 0) 0.0 else ss.last()

    fun reset() {
        xs.clear(); ys.clear(); ss.clear(); es.clear(); segHead.clear(); grid.clear()
        firstElev = null; lastElev = null; dist0 = null
        hasStreak = false; dir = null; streakId = 0; aheadStreak = -1
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
        if (xs.size == 0) {
            lat0 = lat
            lon0 = lon
            cosLat = cos(toRadians(lat))
        }
        val x = (lon - lon0) * M_PER_DEG * cosLat
        val y = (lat - lat0) * M_PER_DEG
        if (xs.size > 0) {
            val step = hyp(x - xs.last(), y - ys.last())
            if (step < MIN_STEP_M || xs.size >= MAX_POINTS) {
                state = state.copy(heightVsStartM = height())
                return state
            }
            if (distM != null) {
                val d0 = dist0 ?: distM.also { dist0 = it }
                ss.add(max(ss.last(), distM - d0))
            } else {
                ss.add(ss.last() + step)
            }
        } else {
            dist0 = distM
            ss.add(0.0)
        }
        xs.add(x); ys.add(y); es.add(elevM ?: Double.NaN)
        if (xs.size >= 2) indexSegment(xs.size - 2)
        update()
        return state
    }

    private fun height(): Double? {
        val a = firstElev
        val b = lastElev
        return if (a == null || b == null) null else b - a
    }

    private fun cellKey(cx: Long, cy: Long): Long = cx * CELL_STRIDE + cy

    private fun indexSegment(k: Int) {
        val r = matchRadiusM
        val x0 = min(xs[k], xs[k + 1]) - r
        val x1 = max(xs[k], xs[k + 1]) + r
        val y0 = min(ys[k], ys[k + 1]) - r
        val y1 = max(ys[k], ys[k + 1]) + r
        val cx1 = floor(x1 / CELL_M).toLong()
        val cy1 = floor(y1 / CELL_M).toLong()
        var cx = floor(x0 / CELL_M).toLong()
        while (cx <= cx1) {
            var cy = floor(y0 / CELL_M).toLong()
            while (cy <= cy1) {
                grid.getOrPut(cellKey(cx, cy)) { IntList() }.add(k)
                cy++
            }
            cx++
        }
    }

    /** Heading of every segment that is now old enough to be asked about, once, in order. */
    private fun matureHeadings(sNow: Double) {
        while (segHead.size + 1 < xs.size - 1 && ss[segHead.size + 1] <= sNow - reverseMinGapM) {
            val j = segHead.size
            var a = j
            while (a > 0 && dist(j, a) < SEG_HALF_WINDOW_M) a--
            var b = j + 1
            while (b < xs.size - 1 && dist(j + 1, b) < SEG_HALF_WINDOW_M) b++
            segHead.add(bearing(xs[a], ys[a], xs[b], ys[b]))
        }
    }

    private fun update() {
        val here = xs.size - 1
        val sNow = ss[here]
        matureHeadings(sNow)
        val head = ownHeading(here)
        var found = false
        var bestDist = 0.0
        var bestS = 0.0
        var bestT = 0.0
        var bestSeg = 0
        var bestDir = RetraceDirection.reverse
        if (head != null && here >= 2) {
            val cell = grid[cellKey(floor(xs[here] / CELL_M).toLong(), floor(ys[here] / CELL_M).toLong())]
            if (cell != null) {
                for (i in 0 until cell.size) {
                    val k = cell.a[i]
                    // Listed in track order: once one is too recent for the shortest gap, all later ones are.
                    if (k + 1 >= here || ss[k + 1] > sNow - reverseMinGapM) break
                    project(k, xs[here], ys[here])
                    val d = projDist
                    if (d > matchRadiusM) continue
                    val diff = angleDiff(head, segHead[k])
                    val dd: RetraceDirection? = if (diff >= 180 - maxHeadingDiffDeg) {
                        RetraceDirection.reverse
                    } else if (diff <= maxHeadingDiffDeg && ss[k + 1] <= sNow - sameMinGapM) {
                        RetraceDirection.same
                    } else {
                        null
                    }
                    if (dd == null) continue
                    // Nearest wins; a tie goes to the earlier segment.
                    if (!found || d < bestDist || (d == bestDist && k < bestSeg)) {
                        found = true
                        bestDist = d
                        bestT = projT
                        bestSeg = k
                        bestS = ss[k] + bestT * (ss[k + 1] - ss[k])
                        bestDir = dd
                    }
                }
            }
        }
        if (found) {
            // The match must move along the old track the way the runner moves along the new one.
            val consistent = hasStreak && dir == bestDir &&
                (if (bestDir == RetraceDirection.reverse) bestS <= matchS + 40 else bestS >= matchS - 40)
            if (!consistent) {
                hasStreak = true
                dir = bestDir
                streakId++
                streakStartS = sNow
                streakStartX = xs[here]
                streakStartY = ys[here]
            }
            lastMatchOwnS = sNow
            matchS = bestS
            matchSeg = bestSeg
            matchT = bestT
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
        if (aheadStreak != streakId || abs(matchS - aheadAtS) >= AHEAD_REFRESH_M) {
            computeAhead(d, here)
            aheadStreak = streakId
            aheadAtS = matchS
        }
        state = RetraceState(
            retracing = true,
            direction = d,
            distanceToStartM = matchS,
            climbAheadM = aheadClimb,
            descentAheadM = aheadDescent,
            heightVsStartM = height(),
        )
    }

    /** Elevation gain and loss on the old stretch still ahead, into the cache. */
    private fun computeAhead(d: RetraceDirection, here: Int) {
        val t = ClimbTracker(ClimbTracker.BARO_THRESHOLD_M)
        var n = 0
        val seg = matchSeg
        val eA = es[seg]
        val eB = es[seg + 1]
        if (!eA.isNaN() && !eB.isNaN()) { t.offer(eA + (eB - eA) * matchT); n++ }
        if (d == RetraceDirection.reverse) {
            var i = seg
            while (i >= 0) {
                val e = es[i]
                if (!e.isNaN()) { t.offer(e); n++ }
                i--
            }
        } else {
            var i = seg + 1
            while (i < here && ss[i] < streakStartS) {
                val e = es[i]
                if (!e.isNaN()) { t.offer(e); n++ }
                i++
            }
        }
        if (n < 2) {
            aheadClimb = null
            aheadDescent = null
        } else {
            aheadClimb = t.ascentM
            aheadDescent = t.descentM
        }
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

    /** Distance from (px, py) to segment [k] into [projDist], and where along it (0..1) into [projT]. */
    private fun project(k: Int, px: Double, py: Double) {
        val ax = xs[k]
        val ay = ys[k]
        val dx = xs[k + 1] - ax
        val dy = ys[k + 1] - ay
        val len2 = dx * dx + dy * dy
        val t = if (len2 == 0.0) 0.0 else (((px - ax) * dx + (py - ay) * dy) / len2).coerceIn(0.0, 1.0)
        val cx = ax + t * dx
        val cy = ay + t * dy
        projDist = hyp(px - cx, py - cy)
        projT = t
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

        /** Most points kept, like the live route's cap; past it the track stops growing. */
        const val MAX_POINTS = 20_000

        /** The old stretch's climb is recomputed only when the match has moved this far (or the streak is new). */
        const val AHEAD_REFRESH_M = 10.0
        private const val CELL_M = 50.0
        private const val CELL_STRIDE = 1_048_576L
        private const val OWN_BASELINE_M = 30.0
        private const val SEG_HALF_WINDOW_M = 25.0
        private const val M_PER_DEG = 111_320.0
        private const val PI = 3.141592653589793
    }
}
