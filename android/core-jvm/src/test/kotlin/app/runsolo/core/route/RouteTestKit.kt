package app.runsolo.core.route

import kotlin.math.cos
import kotlin.math.hypot
import kotlin.random.Random

/** Test helpers: routes and runs drawn in local metres (x east, y north) about a fixed origin. */
object RouteTestKit {
    const val LAT0 = -33.8688
    const val LON0 = 151.2093
    private val kLon = 111_320.0 * cos(Math.toRadians(LAT0))

    fun lat(y: Double) = LAT0 + y / 111_320.0
    fun lon(x: Double) = LON0 + x / kLon

    /** Corner points joined by straight lines and thinned to a point every [stepM] metres. */
    fun densify(corners: List<Pair<Double, Double>>, stepM: Double = 10.0): List<Pair<Double, Double>> {
        val out = ArrayList<Pair<Double, Double>>()
        out.add(corners.first())
        for (i in 1 until corners.size) {
            val (ax, ay) = corners[i - 1]
            val (bx, by) = corners[i]
            val len = hypot(bx - ax, by - ay)
            val n = maxOf(1, Math.ceil(len / stepM).toInt())
            for (k in 1..n) out.add((ax + (bx - ax) * k / n) to (ay + (by - ay) * k / n))
        }
        return out
    }

    fun route(corners: List<Pair<Double, Double>>, stepM: Double = 10.0, elev: ((Int, Pair<Double, Double>) -> Double)? = null, id: String = "r1"): FollowRoute {
        val pts = densify(corners, stepM)
        val ll = ArrayList<Double>()
        for ((x, y) in pts) { ll.add(lat(y)); ll.add(lon(x)) }
        return FollowRoute(id, "Test route", ll, elev?.let { f -> pts.mapIndexed { i, p -> f(i, p) } })
    }

    /** A runner moving at [mps] along [corners], one fix a second, with optional GPS noise of [noiseM] (uniform). */
    class Runner(private val follower: RouteFollower, private val mps: Double = 4.0, private val noiseM: Double = 0.0, seed: Int = 1) {
        private val rnd = Random(seed)
        var t = 0L
        val events = ArrayList<Pair<Long, RouteFollower.Event>>()
        val progress = ArrayList<Double>()

        fun fix(x: Double, y: Double, accuracyM: Double = 5.0) {
            val nx = x + if (noiseM > 0) (rnd.nextDouble() * 2 - 1) * noiseM else 0.0
            val ny = y + if (noiseM > 0) (rnd.nextDouble() * 2 - 1) * noiseM else 0.0
            for (e in follower.offer(t, lat(ny), lon(nx), accuracyM)) events.add(t to e)
            progress.add(follower.progressM)
            t += 1_000
        }

        /** Runs the polyline through [corners], one fix per second at [mps]. */
        fun run(corners: List<Pair<Double, Double>>, accuracyM: Double = 5.0) {
            val dense = densify(corners, stepM = mps)
            for ((x, y) in dense) fix(x, y, accuracyM)
        }

        fun hold(x: Double, y: Double, seconds: Int) { repeat(seconds) { fix(x, y) } }

        val offAlerts get() = events.count { it.second is RouteFollower.Event.OffRoute }
        val backAlerts get() = events.count { it.second is RouteFollower.Event.BackOnRoute }
        val turnCues get() = events.mapNotNull { (it.second as? RouteFollower.Event.Turn)?.text }
    }

    fun follower(route: FollowRoute) = RouteFollower(RoutePath(route))
}
