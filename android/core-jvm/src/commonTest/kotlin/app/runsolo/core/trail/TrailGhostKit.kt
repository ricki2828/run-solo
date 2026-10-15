package app.runsolo.core.trail

import app.runsolo.core.route.RouteFollower
import app.runsolo.core.route.RouteTestKit
import kotlin.math.hypot

/** Test helpers: known trails and runners drawn in local metres, one fix a second. */
object TrailGhostKit {
    /** The trail through [corners], vertices every [stepM] m, with the best run at [bestMps] and the last at [lastMps]. */
    fun trail(
        corners: List<Pair<Double, Double>>,
        bestMps: Double = 4.0,
        lastMps: Double? = 3.5,
        turnAlongM: Double? = null,
        id: String = "t1",
        stepM: Double = 25.0,
        /** Smoothed elevation by distance along the trail, per vertex; null = the run had none. */
        elev: ((Double) -> Double)? = null,
        climbs: List<TrailClimb> = emptyList(),
    ): TrailRef {
        val pts = RouteTestKit.densify(corners, stepM)
        val ll = ArrayList<Double>()
        val cum = ArrayList<Double>()
        var d = 0.0
        for ((i, p) in pts.withIndex()) {
            ll.add(RouteTestKit.lat(p.second)); ll.add(RouteTestKit.lon(p.first))
            if (i > 0) d += hypot(p.first - pts[i - 1].first, p.second - pts[i - 1].second)
            cum.add(d)
        }
        fun profile(runId: String, dateMs: Long, mps: Double) = TrailProfile(runId, dateMs, cum.map { (it / mps * 1000).toLong() })
        return TrailRef(
            id = id, name = "Test trail $id", latLon = ll,
            best = profile("best", 1_000L, bestMps),
            last = lastMps?.let { profile("last", 2_000L, it) },
            turnAlongM = turnAlongM,
            elevM = elev?.let { f -> cum.map { kotlin.math.round(f(it) * 10) / 10.0 } },
            elevSrc = if (elev != null) "baro" else null,
            climbs = climbs,
        )
    }

    /** A runner on [ghost] moving [mps] along a polyline, one accepted fix a second, with an active clock. */
    class Runner(val ghost: TrailGhost, private val mps: Double = 4.0, startActiveMs: Long = 0, private val noiseM: Double = 0.0, seed: Int = 1) {
        private val rnd = kotlin.random.Random(seed)
        var t = 0L
        var activeMs = startActiveMs
        var distM = 0.0
        val states = ArrayList<TrailGhost.TrailState?>()
        val events = ArrayList<Pair<Long, RouteFollower.Event>>()

        fun fix(x: Double, y: Double, accuracyM: Double = 5.0, moving: Boolean = true) {
            val nx = x + if (noiseM > 0) (rnd.nextDouble() * 2 - 1) * noiseM else 0.0
            val ny = y + if (noiseM > 0) (rnd.nextDouble() * 2 - 1) * noiseM else 0.0
            for (e in ghost.offer(t, RouteTestKit.lat(ny), RouteTestKit.lon(nx), accuracyM, activeMs, distM)) events.add(t to e)
            states.add(ghost.state)
            t += 1_000
            if (moving) { activeMs += 1_000; distM += mps }
        }

        fun run(corners: List<Pair<Double, Double>>, accuracyM: Double = 5.0) {
            for ((x, y) in RouteTestKit.densify(corners, stepM = mps)) fix(x, y, accuracyM)
        }

        fun hold(x: Double, y: Double, seconds: Int) { repeat(seconds) { fix(x, y, moving = false) } }

        val turnEvents get() = events.filter { it.second is RouteFollower.Event.RouteEnd }
    }
}
