package app.runsolo.core.ble

import app.runsolo.core.model.HrReading

/**
 * HR → sample join (plan §3): the latest reading at most [maxAgeMs] old, else null. Also null
 * while disconnected (the service calls [disconnected]) so a stale value never rides along.
 */
class HrJoin(private val maxAgeMs: Long = 2_000) {
    private var latest: HrReading? = null

    fun offer(reading: HrReading) {
        latest = reading
    }

    fun disconnected() {
        latest = null
    }

    fun hrAt(t: Long): Int? {
        val r = latest ?: return null
        return if (t - r.t in 0..maxAgeMs) r.bpm else null
    }
}
