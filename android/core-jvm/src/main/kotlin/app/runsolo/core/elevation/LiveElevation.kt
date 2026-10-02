package app.runsolo.core.elevation

/**
 * The live side of elevation: feed it each tick and read the climb so far and the current grade.
 * Wraps the fuser, the climb tracker and the grade window for whichever source the run turns out
 * to have (the first ticks may be GPS-only before the barometer's first batch lands, so the
 * threshold and window are read through [source] each time rather than fixed up front).
 */
class LiveElevation(private val fuser: ElevationFuser = ElevationFuser()) {
    private val baroClimb = ClimbTracker(ClimbTracker.BARO_THRESHOLD_M)
    private val gpsClimb = ClimbTracker(ClimbTracker.GPS_THRESHOLD_M)
    private val baroGrade = GradeWindow(GradeWindow.BARO_WINDOW_M)
    private val gpsGrade = GradeWindow(GradeWindow.GPS_WINDOW_M)
    private var baroGradeNow: Double? = null
    private var gpsGradeNow: Double? = null

    val source: ElevSource? get() = fuser.source
    /** Absolute elevation; null until GPS has set the level (climb and grade do not need it). */
    val elevationM: Double? get() = fuser.elevationM

    /** Ascent so far, metres, by the run's source's threshold; null until there is any elevation. */
    val ascentM: Double? get() = source?.let { tracker(it).ascentM }
    val descentM: Double? get() = source?.let { tracker(it).descentM }

    /** Grade as a fraction (0.05 = 5%), null until a window of distance has been covered. */
    val grade: Double? get() = source?.let { if (it == ElevSource.baro) baroGradeNow else gpsGradeNow }

    private fun tracker(s: ElevSource) = if (s == ElevSource.baro) baroClimb else gpsClimb

    /**
     * One tick. [paused] holds the climb reference (nothing is booked) but the fuser still runs, so
     * the level stays right on resume. [distM] is the live, pause-frozen distance.
     */
    fun offer(t: Long, hpa: Double?, altM: Double?, accuracyM: Double?, distM: Double, paused: Boolean): Double? {
        val e = fuser.offer(t, hpa, altM, accuracyM) ?: return null
        for (tr in listOf(baroClimb, gpsClimb)) if (paused) tr.hold(e) else tr.offer(e)
        baroGradeNow = baroGrade.offer(distM, e)
        gpsGradeNow = gpsGrade.offer(distM, e)
        return e
    }
}
