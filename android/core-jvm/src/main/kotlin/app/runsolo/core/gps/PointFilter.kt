package app.runsolo.core.gps

import app.runsolo.core.model.LocationFix

/**
 * Point acceptance (plan §3): accept a fix if accuracy ≤ [maxAccuracyM] and the speed implied
 * against the last ACCEPTED point is ≤ [maxSpeedMps]; distance is haversine over accepted
 * points only. Deterministic and stateful per run, so the finaliser reproduces the live
 * distance exactly by replaying the raw samples through a fresh instance.
 *
 * Anchoring: the first fix is not trusted on its own (a cold-start network blend can be a few
 * hundred metres off). A point becomes the anchor only when the next fix agrees with it
 * (implied speed ≤ [maxSpeedMps]); the distance between those two counts. Likewise, after
 * [reanchorAfter] consecutive rejections that agree with one another, the track re-anchors
 * on them without adding the jump to the distance (the phone, not the runner, moved).
 *
 * Time is millis on whatever timeline the caller uses (device or run); only deltas matter.
 */
class PointFilter(
    private val maxAccuracyM: Double = 25.0,
    private val maxSpeedMps: Double = 7.0,
    private val reanchorAfter: Int = 3,
) {
    data class Result(val accepted: Boolean, val reason: Reason, val stepM: Double, val totalM: Double)

    enum class Reason { ok, accuracy, speed, notMonotonic, awaitingConfirmation }

    var totalM: Double = 0.0
        private set
    var lastAccepted: LocationFix? = null
        private set
    var acceptedCount: Int = 0
        private set
    var rejectedCount: Int = 0
        private set

    /** Times the track jumped to a new anchor after a run of agreeing rejections. */
    var reanchors: Int = 0
        private set

    private var candidate: LocationFix? = null
    private val rejectedRun = ArrayList<LocationFix>()

    /**
     * Forget the anchor (keep the distance): the next two agreeing fixes anchor afresh and the
     * jump from the old anchor is never counted. Called on resume so movement during a pause
     * (walking to a tap, crossing a road) does not inflate distance or pace.
     */
    fun reanchor() {
        lastAccepted = null
        candidate = null
        rejectedRun.clear()
    }

    fun offer(fix: LocationFix): Result {
        if (fix.accuracyM > maxAccuracyM || fix.accuracyM.isNaN()) return reject(Reason.accuracy)
        val prev = lastAccepted
        if (prev == null) return anchor(fix)
        val dtMs = fix.t - prev.t
        if (dtMs <= 0) return reject(Reason.notMonotonic)
        val step = Geo.haversineM(prev.lat, prev.lon, fix.lat, fix.lon)
        if (step / (dtMs / 1000.0) > maxSpeedMps) {
            rejectedRun.add(fix)
            if (rejectedRun.size >= reanchorAfter && agrees(rejectedRun)) {
                // The runner has been somewhere else for a while: follow them, do not count the jump.
                reanchors++
                lastAccepted = rejectedRun.last()
                rejectedRun.clear()
                rejectedCount++
                return Result(false, Reason.speed, 0.0, totalM)
            }
            return reject(Reason.speed)
        }
        rejectedRun.clear()
        totalM += step
        lastAccepted = fix
        acceptedCount++
        return Result(true, Reason.ok, step, totalM)
    }

    private fun anchor(fix: LocationFix): Result {
        val c = candidate
        if (c == null || fix.t <= c.t) {
            candidate = fix
            rejectedCount++
            return Result(false, Reason.awaitingConfirmation, 0.0, totalM)
        }
        val step = Geo.haversineM(c.lat, c.lon, fix.lat, fix.lon)
        if (step / ((fix.t - c.t) / 1000.0) > maxSpeedMps) {
            candidate = fix // the earlier one was the outlier; try again from here
            rejectedCount++
            return Result(false, Reason.awaitingConfirmation, 0.0, totalM)
        }
        candidate = null
        acceptedCount += 2
        totalM += step
        lastAccepted = fix
        return Result(true, Reason.ok, step, totalM)
    }

    private fun agrees(run: List<LocationFix>): Boolean {
        for (i in 1 until run.size) {
            val a = run[i - 1]
            val b = run[i]
            val dt = b.t - a.t
            if (dt <= 0) return false
            if (Geo.haversineM(a.lat, a.lon, b.lat, b.lon) / (dt / 1000.0) > maxSpeedMps) return false
        }
        return true
    }

    private fun reject(reason: Reason): Result {
        rejectedCount++
        return Result(false, reason, 0.0, totalM)
    }
}
