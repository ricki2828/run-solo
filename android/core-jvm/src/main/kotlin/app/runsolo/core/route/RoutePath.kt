package app.runsolo.core.route

import app.runsolo.core.elevation.ClimbTracker
import kotlin.math.PI
import kotlin.math.abs
import kotlin.math.atan2
import kotlin.math.cos
import kotlin.math.hypot
import kotlin.math.sqrt

/** How sharp a [RouteTurn] is, by the heading change across it (the sign says the side). */
enum class TurnKind { keep, turn, sharp, uTurn }

/** A significant change of heading in the route's shape: [atM] along the route, [angleDeg] positive to the right. */
data class RouteTurn(val atM: Double, val angleDeg: Double, val kind: TurnKind) {
    val right: Boolean get() = angleDeg > 0
}

/** Where a point lands on the route: [alongM] from the start, [offM] away from the line. */
data class RouteHit(val alongM: Double, val offM: Double)

/**
 * The route's geometry in local metres (equirectangular about the first point: a run-sized route is a few km,
 * so the error is far below GPS noise): cumulative distance, climb along it, projection of a position onto a
 * stretch of it, and the turns in its shape. Pure maths, JVM-tested.
 */
class RoutePath(val route: FollowRoute) {
    val size: Int = route.size
    private val x = DoubleArray(size)
    private val y = DoubleArray(size)

    /** Metres from the start at each point. */
    val cum = DoubleArray(size)
    val totalM: Double
    private val lat0 = route.latLon[0]
    private val lon0 = route.latLon[1]
    private val kLon = METRES_PER_DEG * cos(lat0 * PI / 180)

    /** Ascent so far at each point (a dead band on the route's elevation), or null when the route has no elevation. */
    private val climbCum: DoubleArray?
    val totalClimbM: Double?
    val turns: List<RouteTurn>

    init {
        for (i in 0 until size) {
            x[i] = (route.latLon[2 * i + 1] - lon0) * kLon
            y[i] = (route.latLon[2 * i] - lat0) * METRES_PER_DEG
            if (i > 0) cum[i] = cum[i - 1] + hypot(x[i] - x[i - 1], y[i] - y[i - 1])
        }
        totalM = cum[size - 1]
        val ele = route.elevM
        if (ele == null) {
            climbCum = null
            totalClimbM = null
        } else {
            val tracker = ClimbTracker(CLIMB_THRESHOLD_M)
            val c = DoubleArray(size)
            for (i in 0 until size) {
                tracker.offer(ele[i])
                c[i] = tracker.ascentM
            }
            climbCum = c
            totalClimbM = c[size - 1]
        }
        turns = findTurns()
    }

    fun toLocalX(lon: Double): Double = (lon - lon0) * kLon

    fun toLocalY(lat: Double): Double = (lat - lat0) * METRES_PER_DEG

    /** Ascent still ahead from [alongM]; null when the route has no elevation. */
    fun climbToGoM(alongM: Double): Double? {
        val c = climbCum ?: return null
        val a = alongM.coerceIn(0.0, totalM)
        val i = segmentAt(a)
        val segLen = cum[i + 1] - cum[i]
        val f = if (segLen > 0) (a - cum[i]) / segLen else 0.0
        return (totalClimbM!! - (c[i] + (c[i + 1] - c[i]) * f)).coerceAtLeast(0.0)
    }

    /** Index of the segment `[i, i + 1]` holding [alongM] (binary search on [cum]). */
    private fun segmentAt(alongM: Double): Int {
        var lo = 0
        var hi = size - 2
        while (lo < hi) {
            val mid = (lo + hi + 1) ushr 1
            if (cum[mid] <= alongM) lo = mid else hi = mid - 1
        }
        return lo
    }

    /**
     * The nearest point of the route among the stretch from [fromAlongM] to [toAlongM], for the local position
     * ([px], [py]). When the same ground is passed twice in the window (an out-and-back, a loop closing on its
     * start), the earlier pass wins if it is about as near: progress follows the route's order.
     */
    fun nearest(px: Double, py: Double, fromAlongM: Double, toAlongM: Double, tieM: Double): RouteHit? {
        if (toAlongM < fromAlongM) return null
        val first = segmentAt(fromAlongM.coerceIn(0.0, totalM))
        val last = segmentAt(toAlongM.coerceIn(0.0, totalM))
        var best: RouteHit? = null
        val hits = ArrayList<RouteHit>()
        for (i in first..last) {
            val hit = project(i, px, py)
            if (hit.alongM < fromAlongM - 1e-6 || hit.alongM > toAlongM + 1e-6) continue
            hits.add(hit)
            if (best == null || hit.offM < best.offM) best = hit
        }
        best ?: return null
        // An earlier, separate pass over the same ground (not just the neighbouring segments of the same pass).
        val earlier = hits.filter { it.alongM < best.alongM - PASS_GAP_M && it.offM <= best.offM + tieM }
        return earlier.minByOrNull { it.alongM } ?: best
    }

    private fun project(i: Int, px: Double, py: Double): RouteHit {
        val dx = x[i + 1] - x[i]
        val dy = y[i + 1] - y[i]
        val len2 = dx * dx + dy * dy
        val t = if (len2 == 0.0) 0.0 else (((px - x[i]) * dx + (py - y[i]) * dy) / len2).coerceIn(0.0, 1.0)
        val off = hypot(px - (x[i] + t * dx), py - (y[i] + t * dy))
        return RouteHit(cum[i] + t * sqrt(len2), off)
    }

    private fun pointAt(alongM: Double): Pair<Double, Double> {
        val a = alongM.coerceIn(0.0, totalM)
        val i = segmentAt(a)
        val segLen = cum[i + 1] - cum[i]
        val f = if (segLen > 0) (a - cum[i]) / segLen else 0.0
        return (x[i] + (x[i + 1] - x[i]) * f) to (y[i] + (y[i + 1] - y[i]) * f)
    }

    /** Compass bearing, degrees clockwise from north. */
    private fun bearing(a: Pair<Double, Double>, b: Pair<Double, Double>): Double =
        Math.toDegrees(atan2(b.first - a.first, b.second - a.second))

    private fun diff(from: Double, to: Double): Double {
        var d = (to - from) % 360.0
        if (d > 180) d -= 360.0
        if (d <= -180) d += 360.0
        return d
    }

    /**
     * Significant turns from the route's shape alone (no trail data): the heading over the [TURN_LOOK_M] before
     * a point against the heading over the [TURN_LOOK_M] after it, sampled every [TURN_STEP_M]; a stretch where
     * that change stays above [TURN_MIN_DEG] on one side is one turn, placed at its sharpest point.
     */
    private fun findTurns(): List<RouteTurn> {
        if (totalM < 2 * TURN_LOOK_M + TURN_STEP_M) return emptyList()
        val steps = ((totalM - 2 * TURN_LOOK_M) / TURN_STEP_M).toInt() + 1
        val angle = DoubleArray(steps)
        for (k in 0 until steps) {
            val s = TURN_LOOK_M + k * TURN_STEP_M
            val here = pointAt(s)
            angle[k] = diff(bearing(pointAt(s - TURN_LOOK_M), here), bearing(here, pointAt(s + TURN_LOOK_M)))
        }
        val found = ArrayList<RouteTurn>()
        var k = 0
        while (k < steps) {
            if (abs(angle[k]) <= TURN_MIN_DEG) { k++; continue }
            val sign = angle[k] > 0
            var peak = k
            var end = k
            while (end + 1 < steps && abs(angle[end + 1]) > TURN_MIN_DEG && (angle[end + 1] > 0) == sign) {
                end++
                if (abs(angle[end]) > abs(angle[peak])) peak = end
            }
            // Where the change is within a few degrees of its peak: the middle of that plateau is the corner.
            var lo = peak
            var hi = peak
            while (lo > k && abs(angle[lo - 1]) >= abs(angle[peak]) - 5) lo--
            while (hi < end && abs(angle[hi + 1]) >= abs(angle[peak]) - 5) hi++
            val at = TURN_LOOK_M + (lo + hi) / 2.0 * TURN_STEP_M
            found.add(RouteTurn(at, angle[peak], kindOf(abs(angle[peak]))))
            k = end + 1
        }
        // Two bends the same way a few metres apart are one turn.
        val merged = ArrayList<RouteTurn>()
        for (t in found) {
            val prev = merged.lastOrNull()
            if (prev != null && prev.right == t.right && t.atM - prev.atM < TURN_MERGE_M) {
                val sum = prev.angleDeg + t.angleDeg
                merged[merged.size - 1] = RouteTurn((prev.atM + t.atM) / 2, sum, kindOf(abs(sum)))
            } else {
                merged.add(t)
            }
        }
        return merged
    }

    private fun kindOf(deg: Double) = when {
        deg < KEEP_MAX_DEG -> TurnKind.keep
        deg < SHARP_MIN_DEG -> TurnKind.turn
        deg < U_TURN_MIN_DEG -> TurnKind.sharp
        else -> TurnKind.uTurn
    }

    companion object {
        const val METRES_PER_DEG = 111_320.0

        /** A dead band for the route's own elevation: a planned route's elevation is smoother than a barometer's. */
        const val CLIMB_THRESHOLD_M = 4.0

        /** Two points this far apart along the route are different passes over the same ground, not neighbours. */
        const val PASS_GAP_M = 60.0
        const val TURN_LOOK_M = 40.0
        const val TURN_STEP_M = 5.0
        const val TURN_MIN_DEG = 45.0
        const val TURN_MERGE_M = 40.0
        const val KEEP_MAX_DEG = 75.0
        const val SHARP_MIN_DEG = 135.0
        const val U_TURN_MIN_DEG = 165.0
    }
}
