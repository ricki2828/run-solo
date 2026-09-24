package app.runsolo.core.ble

import app.runsolo.core.model.HrReading
import kotlin.math.abs

/**
 * HR → sample join (plan §3): the reading nearest to the sample time within ±[maxAgeMs], else
 * null. Both directions count because a fix is stamped with its fix time
 * (`Location.getElapsedRealtimeNanos`) and delivered a few hundred ms later, by which time
 * the strap's next notification has often already arrived. The last few readings are kept
 * so a burst of notifications does not hide the one that matches.
 *
 * A no-contact packet or a disconnect clears the readings so a stale value never rides along.
 */
class HrJoin(private val maxAgeMs: Long = 2_000, private val keep: Int = 4) {
    private val recent = ArrayDeque<HrReading>()

    fun offer(reading: HrReading) {
        recent.addLast(reading)
        while (recent.size > keep) recent.removeFirst()
    }

    /** Strap says no sensor contact (or reported 0 bpm): forget what we had. */
    fun offerNoContact() = recent.clear()

    fun disconnected() = recent.clear()

    fun hrAt(t: Long): Int? {
        var best: HrReading? = null
        for (r in recent) {
            val d = abs(t - r.t)
            if (d <= maxAgeMs && (best == null || d < abs(t - best.t))) best = r
        }
        return best?.bpm
    }
}
