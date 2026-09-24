package app.runsolo.core.gps

/**
 * Moving / stopped detection from accepted points. Fed the cumulative accepted distance at
 * each accepted sample:
 *  - stopped → moving after [startSamples] consecutive samples whose step speed is
 *    ≥ [minSpeedMps] (two real strides, not one GPS wobble);
 *  - moving → stopped once no sample has advanced the distance by more than [progressEpsM]
 *    for [stopAfterMs] (a kerb wait, a traffic light).
 * [movingMs] accumulates time while moving, for moving time in the summary. It never writes
 * laps or pauses on its own; auto-pause is a UI decision built on this flag.
 */
class MovingDetector(
    private val minSpeedMps: Double = 0.7,
    private val startSamples: Int = 2,
    private val stopAfterMs: Long = 5_000,
    private val progressEpsM: Double = 0.5,
) {
    var moving: Boolean = false
        private set
    var movingMs: Long = 0
        private set

    private var lastT: Long? = null
    private var lastD = 0.0
    private var lastProgressT = 0L
    private var fastStreak = 0

    /** Feed the cumulative accepted distance at time [t] (millis). Returns the moving flag. */
    fun update(t: Long, totalM: Double): Boolean {
        val prevT = lastT
        if (prevT == null) {
            lastT = t
            lastD = totalM
            lastProgressT = t
            return moving
        }
        if (t <= prevT) return moving
        if (moving) movingMs += t - prevT
        val step = totalM - lastD
        val stepSpeed = step / ((t - prevT) / 1000.0)
        fastStreak = if (stepSpeed >= minSpeedMps) fastStreak + 1 else 0
        if (step > progressEpsM) lastProgressT = t
        moving = if (moving) t - lastProgressT < stopAfterMs else fastStreak >= startSamples
        lastT = t
        lastD = totalM
        return moving
    }
}
