package app.runsolo.core.trail

import app.runsolo.core.route.RouteFollower

/**
 * The one door for the trail ghost on the recorder thread. The ghost is a convenience, never a reason to lose a
 * run (the RetraceDetector out-of-memory lesson): any failure, while building or while ticking, switches it off
 * for the rest of the run, drops its memory and calls [onFailure] once; every later [offer] is a no-op.
 */
class TrailGhostFeed(
    trails: List<TrailRef>,
    private val onFailure: ((Throwable) -> Unit)? = null,
    build: (List<TrailRef>) -> TrailGhost = { TrailGhost(it) },
) {
    private var ghost: TrailGhost? = null

    /** The failure that disabled the ghost, or null while it works (or when there is nothing to match). */
    var failure: Throwable? = null
        private set

    init {
        if (trails.isNotEmpty()) {
            try {
                ghost = build(trails)
            } catch (t: Throwable) {
                fail(t)
            }
        }
    }

    /** True when there is a ghost to feed. */
    val active: Boolean get() = ghost != null

    fun offer(t: Long, lat: Double, lon: Double, accuracyM: Double, activeMs: Long, runDistM: Double): List<RouteFollower.Event> {
        val g = ghost ?: return emptyList()
        return try {
            g.offer(t, lat, lon, accuracyM, activeMs, runDistM)
        } catch (e: Throwable) {
            fail(e)
            emptyList()
        }
    }

    /** Null until a trail is matched, and once disabled. */
    val state: TrailGhost.TrailState? get() = ghost?.state

    private fun fail(t: Throwable) {
        failure = t
        ghost = null
        try { onFailure?.invoke(t) } catch (ignored: Throwable) { }
    }
}
