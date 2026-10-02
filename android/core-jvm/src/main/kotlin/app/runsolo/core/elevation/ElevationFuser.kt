package app.runsolo.core.elevation

import kotlin.math.exp
import kotlin.math.pow

/** Where a run's elevation came from. Written to the run file as `elev_src`. */
enum class ElevSource(val wire: String) {
    baro("baro"),
    gps("gps"),
    ;

    companion object {
        fun fromWire(s: String?): ElevSource? = values().firstOrNull { it.wire == s }
    }
}

/**
 * Fuses the phone's barometer with GPS altitude into one elevation per tick. Pure: the caller
 * owns the clock and feeds [offer] in time order, so the live recorder and the run-file builder
 * (which replays the journal) get the same numbers.
 *
 * The barometer is good at change (a metre or so over a hill) and bad at the absolute level
 * (weather moves the reading by tens of metres over a day); GPS altitude is the other way
 * round. So the barometer carries the shape and GPS anchors the level, slowly:
 *  - pressure becomes altitude with the international barometric formula, then a short low-pass
 *    takes the sensor jitter off;
 *  - the mean of the first twenty usable GPS altitudes sets the level; after that the offset between the two is
 *    nudged toward GPS with a long time constant and a rate cap, so a weather front (about 1 hPa
 *    in 3 hours, 8 m) is followed but the correction itself never reads as a climb;
 *  - with no barometer (or a tick with no reading) the estimate follows GPS altitude through a
 *    smoothing filter, and the run is flagged [ElevSource.gps]: noisier, so the climb threshold is
 *    larger ([ClimbTracker.GPS_THRESHOLD_M]).
 */
class ElevationFuser(
    private val baroTauS: Double = 2.0,
    private val anchorTauS: Double = 900.0,
    private val anchorFixes: Int = 20,
    private val anchorMaxRateMps: Double = 0.01,
    private val gpsSmoothTauS: Double = 15.0,
    private val maxGpsAccuracyM: Double = 30.0,
    private val baroLostAfterMs: Long = 5_000,
) {
    private var lastT: Long? = null
    private var est: Double? = null
    private var baroF: Double? = null
    private var offset: Double? = null
    private var lastBaroT: Long? = null
    private var anchorSum = 0.0
    private var anchorCount = 0
    private var baroTicks = 0
    private var gpsTicks = 0

    /** The latest estimate in metres, or null until there was anything to go on. */
    val elevationM: Double? get() = est

    /** Baro when most estimates came from the barometer, else GPS; null before the first estimate. */
    val source: ElevSource?
        get() = if (baroTicks + gpsTicks == 0) null else if (baroTicks >= gpsTicks) ElevSource.baro else ElevSource.gps

    /**
     * One tick: [hpa] the latest pressure (null = none), [altM]/[accuracyM] the fix's altitude and
     * horizontal accuracy (null = no fix). Returns the elevation at [t], or null while there is none (no level yet, or this tick had no reading and no fix).
     */
    fun offer(t: Long, hpa: Double?, altM: Double?, accuracyM: Double?): Double? {
        val dt = lastT?.let { ((t - it) / 1000.0).coerceIn(0.0, 30.0) } ?: 0.0
        lastT = t
        val gpsOk = altM != null && altM.isFinite() && accuracyM != null && accuracyM <= maxGpsAccuracyM
        val baroOk = hpa != null && hpa.isFinite() && hpa in 300.0..1100.0
        var fresh = false
        if (baroOk) {
            val raw = altitudeOfPressure(hpa!!)
            val prev = baroF
            baroF = if (prev == null || lastBaroT?.let { t - it > baroLostAfterMs } != false) raw else prev + (raw - prev) * (1 - exp(-dt / baroTauS))
            lastBaroT = t
            val b = baroF!!
            val off = offset
            if (off == null) {
                // First reading, or the barometer came back: carry on from the current level. A
                // run's first level is the mean of its first [anchorFixes] usable GPS altitudes (one
                // fix is off by ten metres), and until then there is no estimate: no level, no elevation.
                val e = est
                if (e != null) {
                    offset = e - b
                } else if (gpsOk) {
                    anchorSum += altM!! - b
                    if (++anchorCount >= anchorFixes) offset = anchorSum / anchorCount
                }
            } else if (gpsOk && dt > 0) {
                val err = altM!! - (b + off)
                val step = (err * dt / anchorTauS).coerceIn(-anchorMaxRateMps * dt, anchorMaxRateMps * dt)
                offset = off + step
            }
            offset?.let {
                est = b + it
                baroTicks++
                fresh = true
            }
        } else {
            // Barometer silent: GPS carries the estimate, and the offset is re-taken when the sensor returns.
            if (lastBaroT?.let { t - it > baroLostAfterMs } != false) offset = null
            if (gpsOk) {
                val e = est
                est = if (e == null) altM else e + (altM!! - e) * (1 - exp(-dt / gpsSmoothTauS))
                gpsTicks++
                fresh = true
            }
        }
        // A tick with nothing to go on holds the estimate inside but reports none: no value is better than a stale one.
        return if (fresh) est else null
    }

    companion object {
        /** International barometric formula against the standard sea-level pressure. */
        fun altitudeOfPressure(hpa: Double): Double = 44_330.77 * (1.0 - (hpa / 1013.25).pow(0.190263))
    }
}
