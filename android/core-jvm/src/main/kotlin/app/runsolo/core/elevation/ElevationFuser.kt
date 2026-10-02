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
 * round. So the estimate is split in two:
 *  - the RELATIVE series ([offer]'s return value): the barometer's altitude (international
 *    barometric formula, short low-pass) plus a slow, rate-capped drift correction toward GPS. It
 *    is continuous from the first tick, so climb and grade (which only read differences) count a
 *    hill in the first seconds, and nothing the level does can read as a climb;
 *  - the LEVEL ([levelM]): the mean of the first twenty usable GPS altitudes minus the relative
 *    series. Absolute elevation is relative + level, so whoever stores absolute values (the run
 *    file) adds the final level to every tick, the early ones included.
 *
 * With no barometer, or after it has been silent for [baroLostAfterMs], the series follows
 * smoothed GPS altitude and the run is flagged [ElevSource.gps] (noisier, so the climb threshold
 * is larger). When the barometer comes back it carries on from where the series was (no fake
 * step), whatever GPS said in between.
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
    private var rel: Double? = null
    private var level: Double? = null
    private var drift = 0.0
    private var baroF: Double? = null
    private var lastBaroT: Long? = null
    private var anchorSum = 0.0
    private var anchorCount = 0
    private var baroTicks = 0
    private var gpsTicks = 0

    /** The latest relative elevation, or null before anything was read. */
    val relativeM: Double? get() = rel

    /** Absolute = relative + level; null until a usable GPS altitude has set it. */
    val levelM: Double? get() = level

    /** The latest absolute elevation in metres; null while there is no level yet. */
    val elevationM: Double? get() = rel?.let { r -> level?.let { r + it } }

    /** Baro when most ticks came from the barometer, else GPS; null before the first estimate. */
    val source: ElevSource?
        get() = if (baroTicks + gpsTicks == 0) null else if (baroTicks >= gpsTicks) ElevSource.baro else ElevSource.gps

    /**
     * One tick: [hpa] the latest pressure (null = none), [altM]/[accuracyM] the fix's altitude and
     * horizontal accuracy (null = no fix). Returns the RELATIVE elevation at [t] (add [levelM] for
     * metres above sea level), or null while there is none (nothing read yet, or no fix and no
     * barometer).
     */
    fun offer(t: Long, hpa: Double?, altM: Double?, accuracyM: Double?): Double? {
        val dt = lastT?.let { ((t - it) / 1000.0).coerceIn(0.0, 30.0) } ?: 0.0
        lastT = t
        val gpsOk = altM != null && altM.isFinite() && accuracyM != null && accuracyM <= maxGpsAccuracyM
        val baroOk = hpa != null && hpa.isFinite() && hpa in 300.0..1100.0
        val baroRecent = lastBaroT?.let { t - it <= baroLostAfterMs } == true
        if (baroOk) {
            val raw = altitudeOfPressure(hpa!!)
            val prev = baroF
            baroF = if (prev == null || !baroRecent) raw else prev + (raw - prev) * (1 - exp(-dt / baroTauS))
            val b = baroF!!
            val before = rel
            // Back after a gap (or the first reading): carry on from where the series was.
            if (before == null) drift = 0.0 else if (!baroRecent) drift = before - b
            lastBaroT = t
            if (gpsOk) {
                val lv = level
                if (lv == null) {
                    anchorSum += altM!! - (b + drift)
                    if (++anchorCount >= anchorFixes) level = anchorSum / anchorCount
                } else if (dt > 0) {
                    val err = altM!! - (b + drift + lv)
                    drift += (err * dt / anchorTauS).coerceIn(-anchorMaxRateMps * dt, anchorMaxRateMps * dt)
                }
            }
            rel = b + drift
            baroTicks++
        } else if (!baroRecent && gpsOk) {
            // No barometer (or silent for a while): GPS carries the series.
            val r = rel
            val lv = level
            if (r == null) {
                rel = altM
                level = 0.0
            } else {
                val l = lv ?: (altM!! - r).also { level = it }
                val abs = r + l
                rel = abs + (altM!! - abs) * (1 - exp(-dt / gpsSmoothTauS)) - l
            }
            gpsTicks++
        } else if (!baroRecent) {
            return null
        }
        // A short barometer gap with no reading holds the series (no hole in the file).
        return rel
    }

    companion object {
        /** International barometric formula against the standard sea-level pressure. */
        fun altitudeOfPressure(hpa: Double): Double = 44_330.77 * (1.0 - (hpa / 1013.25).pow(0.190263))
    }
}
