package app.runsolo.core.trail

import app.runsolo.core.json.double
import app.runsolo.core.json.doubleOrNull
import app.runsolo.core.json.list
import app.runsolo.core.json.long
import app.runsolo.core.json.obj
import app.runsolo.core.json.string
import app.runsolo.core.route.FollowRoute

/**
 * One earlier run of a known trail as a progress profile: [ms] is the moving time since that run's start at each
 * vertex of the [TrailRef] geometry (-1 where the run did not reach, a shorter run), so "time at distance along the
 * trail" reads the same for every run, whatever its own length. Built by the app from the run file.
 */
data class TrailProfile(val runId: String, val dateMs: Long, val ms: List<Long>) {
    fun toJson(): Map<String, Any?> = linkedMapOf("runId" to runId, "dateMs" to dateMs, "ms" to ms)

    companion object {
        fun fromJson(m: Map<String, Any?>) = TrailProfile(
            runId = m.string("runId"),
            dateMs = m.long("dateMs"),
            ms = m.list("ms").map { (it as? Number ?: throw IllegalArgumentException("trail ms")).toLong() },
        )
    }
}

/** A climb on a trail, in metres along it: where it starts and ends, what it gains and its average grade in percent. */
data class TrailClimb(val startM: Double, val endM: Double, val gainM: Double, val avgGradePct: Double) {
    fun toJson(): Map<String, Any?> = linkedMapOf("s" to startM, "e" to endM, "g" to gainM, "p" to avgGradePct)

    companion object {
        fun fromJson(m: Map<String, Any?>) = TrailClimb(m.double("s"), m.double("e"), m.double("g"), m.double("p"))

        /** True for a climb that is finite and runs forward; an odd one from a newer or buggy app is dropped, not fatal. */
        fun sane(c: TrailClimb) =
            c.startM.isFinite() && c.endM.isFinite() && c.gainM.isFinite() && c.avgGradePct.isFinite() &&
                c.startM >= 0 && c.endM > c.startM && c.gainM > 0
    }
}

/**
 * A trail the runner has run before, handed to the recorder at Start inside the live context (bounded: at most
 * [MAX_POINTS] vertices, never a run file). [latLon] is the trail's geometry, flat `[lat, lon, ...]`, resampled by
 * the app; [best] and [last] are the profiles of the fastest and the most recent run on it (null [last] = the last
 * run is the best). [turnAlongM] is where the trail turns round when it is an out-and-back, else null.
 *
 * [elevM] is the trail's elevation smoothed over at least 50 m, one value per vertex ([elevSrc] `baro` or `gps`), and
 * [climbs] its climbs in trail order (empty unless the barometer made the profile). Elevation is a convenience: it is
 * never validated hard, so a bad profile is ignored ([elevation]) and cannot drop the whole live context.
 */
data class TrailRef(
    val id: String,
    val name: String,
    val latLon: List<Double>,
    val best: TrailProfile,
    val last: TrailProfile? = null,
    val turnAlongM: Double? = null,
    val elevM: List<Double>? = null,
    val elevSrc: String? = null,
    val climbs: List<TrailClimb> = emptyList(),
) {
    init {
        require(latLon.size % 2 == 0) { "trail latLon must be pairs" }
        val n = latLon.size / 2
        require(n in FollowRoute.MIN_POINTS..MAX_POINTS) { "a trail has ${FollowRoute.MIN_POINTS}..$MAX_POINTS points, got $n" }
        for (i in latLon.indices step 2) {
            require(latLon[i].isFinite() && latLon[i] in -90.0..90.0) { "trail latitude out of range" }
            require(latLon[i + 1].isFinite() && latLon[i + 1] in -180.0..180.0) { "trail longitude out of range" }
        }
        require(best.ms.size == n) { "trail best profile needs one time per point" }
        require(last == null || last.ms.size == n) { "trail last profile needs one time per point" }
        require(turnAlongM == null || (turnAlongM.isFinite() && turnAlongM > 0)) { "trail turn must be positive" }
    }

    /** [elevM] when it fits the geometry and is finite, else null: the ghost then has no profile, nothing more. */
    val elevation: List<Double>? get() = elevM?.takeIf { it.size == latLon.size / 2 && it.all { v -> v.isFinite() } }

    /** [climbs] that are well formed and lie on the trail. */
    val sensibleClimbs: List<TrailClimb> get() = if (elevation == null) emptyList() else climbs.filter { TrailClimb.sane(it) }.take(MAX_CLIMBS)

    fun toJson(): Map<String, Any?> = linkedMapOf<String, Any?>(
        "id" to id, "name" to name, "ll" to latLon, "best" to best.toJson(), "last" to last?.toJson(), "turnM" to turnAlongM,
    ).also {
        if (elevM != null) it["elev"] = elevM
        if (elevSrc != null) it["elevSrc"] = elevSrc
        if (climbs.isNotEmpty()) it["climbs"] = climbs.map { c -> c.toJson() }
    }

    companion object {
        /** Hard cap on the geometry: a bounded payload and a bounded per-fix search. */
        const val MAX_POINTS = 400
        const val MAX_TRAILS = 6
        const val MAX_CLIMBS = 12

        fun fromJson(m: Map<String, Any?>) = TrailRef(
            id = m.string("id"),
            name = m.string("name"),
            latLon = m.list("ll").map { (it as? Number ?: throw IllegalArgumentException("trail ll")).toDouble() },
            best = TrailProfile.fromJson(m.obj("best") ?: throw IllegalArgumentException("trail.best")),
            last = m.obj("last")?.let { TrailProfile.fromJson(it) },
            turnAlongM = m.doubleOrNull("turnM"),
            elevM = (m["elev"] as? List<*>)?.mapNotNull { (it as? Number)?.toDouble() },
            elevSrc = m["elevSrc"] as? String,
            climbs = (m["climbs"] as? List<*>).orEmpty().mapNotNull { c ->
                val fields = (c as? Map<*, *>)?.entries?.associate { (k, v) -> k.toString() to v }
                fields?.let { runCatching { TrailClimb.fromJson(it) }.getOrNull() }
            },
        )
    }
}
