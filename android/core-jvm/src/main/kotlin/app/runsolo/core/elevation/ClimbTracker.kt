package app.runsolo.core.elevation

/**
 * Total ascent and descent with a dead band, so sensor noise is not counted as hills. The
 * reference level only moves once the elevation has left it by [thresholdM]; that whole step is
 * then booked as climb or descent. A flat run wobbling by less than the threshold books nothing.
 * The Dart engine runs the same rule over the run file (`ClimbTracker` in run_engine), so the
 * live total and the finished one agree.
 */
class ClimbTracker(val thresholdM: Double) {
    private var ref: Double? = null

    var ascentM: Double = 0.0
        private set
    var descentM: Double = 0.0
        private set

    fun offer(elevM: Double) {
        val r = ref
        if (r == null) {
            ref = elevM
            return
        }
        val d = elevM - r
        if (d >= thresholdM) {
            ascentM += d
            ref = elevM
        } else if (-d >= thresholdM) {
            descentM += -d
            ref = elevM
        }
    }

    /** Follow [elevM] without booking it (paused: the walk to the cafe is not part of the run). */
    fun hold(elevM: Double) {
        ref = elevM
    }

    companion object {
        /** Barometer: about 3 m, a little over the sensor's noise. */
        const val BARO_THRESHOLD_M = 3.0

        /** GPS altitude alone is far noisier. */
        const val GPS_THRESHOLD_M = 10.0

        fun thresholdFor(src: ElevSource): Double = if (src == ElevSource.baro) BARO_THRESHOLD_M else GPS_THRESHOLD_M
    }
}
