package app.runsolo.core.elevation

/**
 * Grade (rise over run) over the last [windowM] metres of distance: the elevation now against
 * the elevation one window ago. Null until a window of distance has been covered, so a few
 * metres of noise can never read as a 30% wall. Clamped to +/-45%, the range the cost model
 * covers.
 */
class GradeWindow(private val windowM: Double) {
    private data class P(val d: Double, val e: Double)

    private val pts = ArrayDeque<P>()

    fun offer(distM: Double, elevM: Double): Double? {
        pts.addLast(P(distM, elevM))
        // The anchor is the newest point at least one window back; everything before it is dropped.
        while (pts.size > 1 && pts[1].d <= distM - windowM) pts.removeFirst()
        val a = pts.first()
        val span = distM - a.d
        if (span < windowM) return null
        return ((elevM - a.e) / span).coerceIn(-MAX_GRADE, MAX_GRADE)
    }

    fun reset() = pts.clear()

    companion object {
        const val MAX_GRADE = 0.45
        const val BARO_WINDOW_M = 50.0
        const val GPS_WINDOW_M = 100.0

        fun windowFor(src: ElevSource): Double = if (src == ElevSource.baro) BARO_WINDOW_M else GPS_WINDOW_M
    }
}
