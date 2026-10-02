package app.runsolo.core.elevation

/**
 * Total ascent and descent with a dead band, so sensor noise is not counted as hills. A turning
 * point (the top of a hill, the bottom of a dip) is only believed once the elevation has come back
 * [thresholdM] from it; a move from the last turning point only starts counting once it is
 * [thresholdM] long. After that every metre further along the same direction counts at once, so
 * the live total is never a threshold behind and a hill is booked right up to its top. A flat run
 * wobbling by less than the threshold books nothing.
 *
 * The Dart engine runs the same rule over the run file (`ClimbTracker` in run_engine), so the live
 * total and the finished one agree.
 */
class ClimbTracker(val thresholdM: Double) {
    private var ref: Double? = null
    private var ext = 0.0
    private var dir = 0

    var ascentM: Double = 0.0
        private set
    var descentM: Double = 0.0
        private set

    fun offer(elevM: Double) {
        val r = ref
        if (r == null) {
            ref = elevM
            ext = elevM
            return
        }
        when (dir) {
            0 -> if (elevM - r >= thresholdM) {
                ascentM += elevM - r
                dir = 1
                ext = elevM
            } else if (r - elevM >= thresholdM) {
                descentM += r - elevM
                dir = -1
                ext = elevM
            }
            1 -> if (elevM > ext) {
                ascentM += elevM - ext
                ext = elevM
            } else if (ext - elevM >= thresholdM) {
                descentM += ext - elevM
                dir = -1
                ref = ext
                ext = elevM
            }
            else -> if (elevM < ext) {
                descentM += ext - elevM
                ext = elevM
            } else if (elevM - ext >= thresholdM) {
                ascentM += elevM - ext
                dir = 1
                ref = ext
                ext = elevM
            }
        }
    }

    /** Follow [elevM] without booking it (paused: the walk to the cafe is not part of the run). */
    fun hold(elevM: Double) {
        ref = elevM
        ext = elevM
        dir = 0
    }

    companion object {
        /** Barometer: about 3 m, a little over the sensor's noise. */
        const val BARO_THRESHOLD_M = 3.0

        /** GPS altitude alone is far noisier. */
        const val GPS_THRESHOLD_M = 10.0

        fun thresholdFor(src: ElevSource): Double = if (src == ElevSource.baro) BARO_THRESHOLD_M else GPS_THRESHOLD_M
    }
}
