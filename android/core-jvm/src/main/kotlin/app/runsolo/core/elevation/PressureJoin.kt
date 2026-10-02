package app.runsolo.core.elevation

import kotlin.math.abs

/** One barometer reading: [t] is device monotonic millis (the sensor event's timestamp), [hpa] the pressure. */
data class PressureReading(val t: Long, val hpa: Double)

/**
 * Pressure -> sample join, the barometer's twin of `HrJoin`: the reading nearest to the sample
 * time within +/-[maxAgeMs], else null. The sensor delivers in batches (it is asked for about
 * 1 Hz with a few seconds of report latency to save power), so a reading usually arrives after the
 * sample it belongs to; its own timestamp is what matters.
 */
class PressureJoin(private val maxAgeMs: Long = 3_000, private val keep: Int = 12) {
    private val recent = ArrayDeque<PressureReading>()

    fun offer(reading: PressureReading) {
        recent.addLast(reading)
        while (recent.size > keep) recent.removeFirst()
    }

    fun hpaAt(t: Long): Double? {
        var best: PressureReading? = null
        for (r in recent) {
            val d = abs(t - r.t)
            if (d <= maxAgeMs && (best == null || d < abs(t - best.t))) best = r
        }
        return best?.hpa
    }
}
