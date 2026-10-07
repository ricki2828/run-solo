package app.runsolo.core.route

import app.runsolo.core.json.list
import app.runsolo.core.json.string

/**
 * A route the runner chose to follow (Follow a route, level 1 and 2). Built by the app from a GPX/TCX file or a
 * past run, simplified on the Dart side, handed to `start()`, journaled as the `route` line right after the header
 * and rebuilt from it on restore. [latLon] is flat `[lat, lon, ...]` in route order; [elevM] is one elevation per
 * point, or null when the route has none (no climb to go then). Mirrors the Pigeon `FollowRoute`.
 */
class FollowRoute(
    val id: String,
    val name: String,
    val latLon: List<Double>,
    val elevM: List<Double>? = null,
) {
    init {
        require(latLon.size % 2 == 0) { "route latLon must be pairs" }
        require(latLon.size / 2 in MIN_POINTS..MAX_POINTS) { "a route has $MIN_POINTS..$MAX_POINTS points, got ${latLon.size / 2}" }
        for (i in latLon.indices step 2) {
            require(latLon[i].isFinite() && latLon[i] in -90.0..90.0) { "route latitude out of range" }
            require(latLon[i + 1].isFinite() && latLon[i + 1] in -180.0..180.0) { "route longitude out of range" }
        }
        require(elevM == null || (elevM.size == latLon.size / 2 && elevM.all { it.isFinite() })) { "route elevations must be one per point" }
    }

    val size: Int get() = latLon.size / 2

    fun toJson(): Map<String, Any?> = linkedMapOf("id" to id, "name" to name, "ll" to latLon, "ele" to elevM)

    companion object {
        const val MIN_POINTS = 2
        const val MAX_POINTS = 5_000

        fun fromJson(m: Map<String, Any?>): FollowRoute {
            val ele = m["ele"] as? List<*>
            return FollowRoute(
                id = m.string("id"),
                name = m.string("name"),
                latLon = m.list("ll").map { (it as Number).toDouble() },
                elevM = ele?.map { (it as Number).toDouble() },
            )
        }
    }
}
