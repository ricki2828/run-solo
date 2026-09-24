package app.runsolo.core.gps

import app.runsolo.core.model.LocationFix

/**
 * Point acceptance (plan §3): accept a fix if accuracy ≤ [maxAccuracyM] and the speed implied
 * against the last ACCEPTED point is ≤ [maxSpeedMps]; distance is haversine over accepted
 * points only. Deterministic and stateful per run, so the finaliser reproduces the live
 * distance exactly by replaying the raw samples through a fresh instance.
 *
 * Time is millis on whatever timeline the caller uses (device or run); only deltas matter.
 */
class PointFilter(
    private val maxAccuracyM: Double = 25.0,
    private val maxSpeedMps: Double = 7.0,
) {
    data class Result(val accepted: Boolean, val reason: Reason, val stepM: Double, val totalM: Double)

    enum class Reason { ok, accuracy, speed, notMonotonic }

    var totalM: Double = 0.0
        private set
    var lastAccepted: LocationFix? = null
        private set
    var acceptedCount: Int = 0
        private set
    var rejectedCount: Int = 0
        private set

    fun offer(fix: LocationFix): Result {
        if (fix.accuracyM > maxAccuracyM || fix.accuracyM.isNaN()) return reject(Reason.accuracy)
        val prev = lastAccepted
        if (prev == null) {
            lastAccepted = fix
            acceptedCount++
            return Result(true, Reason.ok, 0.0, totalM)
        }
        val dtMs = fix.t - prev.t
        if (dtMs <= 0) return reject(Reason.notMonotonic)
        val step = Geo.haversineM(prev.lat, prev.lon, fix.lat, fix.lon)
        val implied = step / (dtMs / 1000.0)
        if (implied > maxSpeedMps) return reject(Reason.speed)
        totalM += step
        lastAccepted = fix
        acceptedCount++
        return Result(true, Reason.ok, step, totalM)
    }

    private fun reject(reason: Reason): Result {
        rejectedCount++
        return Result(false, reason, 0.0, totalM)
    }
}
