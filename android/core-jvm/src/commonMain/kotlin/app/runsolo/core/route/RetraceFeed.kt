package app.runsolo.core.route

/**
 * The one rule for which fixes reach the [RetraceDetector], used by the live recorder and by the
 * restore after a kill, so both build the same track from the same journal:
 *  - only while the run is actively recording (not paused, not auto-paused: the jitter of a
 *    runner standing at a junction must not become track);
 *  - only accepted fixes (accuracy within [MAX_ACCURACY_M], the live map's cut);
 *  - elevation only from the barometer ([baro]), never GPS altitude and never a mix of the two,
 *    the same rule the check-in's height vs start follows;
 *  - [distM] is the recorder's own filtered distance after this fix (the same value live and on
 *    restore).
 */
class RetraceFeed(val detector: RetraceDetector = RetraceDetector()) {
    /** Returns the state after the fix, or null when the fix was not used. */
    fun offer(
        lat: Double,
        lon: Double,
        accuracyM: Double,
        elevM: Double?,
        baro: Boolean,
        distM: Double,
        active: Boolean,
    ): RetraceState? {
        if (!active || accuracyM > MAX_ACCURACY_M) return null
        return detector.add(lat, lon, if (baro) elevM else null, distM)
    }

    val state: RetraceState get() = detector.state

    companion object {
        /** Same accuracy cut as the live map route: a poorer fix is not a place on the track. */
        const val MAX_ACCURACY_M = 25.0
    }
}
