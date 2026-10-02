package app.runsolo.core.gps

/**
 * Moving / stopped detection from accepted points. Fed the cumulative accepted distance at
 * each accepted sample (and, when the fix has them, its reported speed and position):
 *  - stopped → moving after [startSamples] consecutive samples at or above [minSpeedMps]
 *    (two real strides, not one GPS wobble);
 *  - moving → stopped once nothing has counted as progress for [stopAfterMs] (a kerb wait, a
 *    traffic light).
 * What counts as progress depends on what the sample carries, best first:
 *  1. the fix's own speed (Doppler, near zero when standing) at or above [stallSpeedMps];
 *  2. a position more than [anchorRadiusM] from where progress was last seen (GPS jitter
 *     wanders inside that circle; a walker leaves it within the stop window);
 *  3. the accepted distance advancing by more than [progressEpsM] in one step.
 * A start also needs the net displacement over its streak, so jitter that adds path length
 * but goes nowhere never starts it. A gap in the samples longer than [maxGapMs] (a tunnel, a
 * kill) is not evidence of standing still: the stop timer and the start streak restart.
 * [movingMs] accumulates time while moving, for moving time in the summary. It never writes
 * laps or pauses on its own; [RecorderCore.autoPause] is built on this flag.
 */
class MovingDetector(
    private val minSpeedMps: Double = 0.7,
    private val startSamples: Int = 2,
    private val stopAfterMs: Long = 5_000,
    private val progressEpsM: Double = 0.5,
    private val stallSpeedMps: Double = 0.5,
    private val anchorRadiusM: Double = 3.0,
    private val maxGapMs: Long = Long.MAX_VALUE,
) {
    var moving: Boolean = false
        private set
    var movingMs: Long = 0
        private set

    private var lastT: Long? = null
    private var lastD = 0.0
    private var lastProgressT = 0L
    private var fastStreak = 0
    private var anchor: Pair<Double, Double>? = null
    private val recent = ArrayDeque<Triple<Long, Double, Double>>()

    /** Feed the cumulative accepted distance at time [t] (millis). Returns the moving flag. */
    fun update(t: Long, totalM: Double, speedMps: Double? = null, lat: Double? = null, lon: Double? = null): Boolean {
        val prevT = lastT
        val pos = if (lat != null && lon != null) lat to lon else null
        if (prevT == null) {
            lastT = t
            lastD = totalM
            lastProgressT = t
            anchor = pos
            return moving
        }
        if (t <= prevT) return moving
        if (t - prevT > maxGapMs) {
            // Not evidence either way: start the stop timer and the start streak over.
            lastProgressT = t
            fastStreak = 0
            anchor = pos
            recent.clear()
            lastT = t
            lastD = totalM
            return moving
        }
        if (moving) movingMs += t - prevT
        val step = totalM - lastD
        val speed = speedMps ?: (step / ((t - prevT) / 1000.0))
        if (pos != null) {
            recent.addLast(Triple(t, pos.first, pos.second))
            while (recent.size > startSamples + 1) recent.removeFirst()
        }
        val fast = speed >= minSpeedMps && wentSomewhere()
        fastStreak = if (fast) fastStreak + 1 else 0
        val progress = when {
            speedMps != null -> speedMps >= stallSpeedMps
            pos != null && anchor != null -> Geo.haversineM(anchor!!.first, anchor!!.second, pos.first, pos.second) > anchorRadiusM
            else -> step > progressEpsM
        }
        if (progress) {
            lastProgressT = t
            anchor = pos
        }
        moving = if (moving) t - lastProgressT < stopAfterMs else fastStreak >= startSamples
        lastT = t
        lastD = totalM
        return moving
    }

    /** The streak's net displacement agrees with its speed (when positions are known): jitter returns to where it began. */
    private fun wentSomewhere(): Boolean {
        if (recent.size < 2) return true
        val a = recent.first()
        val b = recent.last()
        val secs = (b.first - a.first) / 1000.0
        if (secs <= 0) return true
        return Geo.haversineM(a.second, a.third, b.second, b.third) / secs >= minSpeedMps * 0.6
    }

    companion object {
        /**
         * The auto-pause preset: stop after 4.5 s without progress, restart after 3 samples at
         * a jog or better (1 m/s), standing is below 0.5 m/s, a gap over 3 s is not a stop.
         * The real-world values are unverified until a device run.
         */
        fun forAutoPause() = MovingDetector(
            minSpeedMps = 1.0,
            startSamples = 3,
            stopAfterMs = 4_500,
            stallSpeedMps = 0.5,
            anchorRadiusM = 3.0,
            maxGapMs = 3_000,
        )
    }
}
