package app.runsolo.core.live

import app.runsolo.core.record.CueWords
import kotlin.math.abs
import kotlin.math.roundToInt
import kotlin.math.roundToLong

/**
 * What a Free or Trail run's km check-in says (Settings → Voice → "Check-in"). The order here is the
 * spoken order and the importance order: when the line would run long, the last chosen metrics go.
 * [key] is the stable name stored in settings and sent over Pigeon; unknown keys are ignored.
 */
enum class CheckInMetric(val key: String) {
    distance("distance"),
    time("time"),
    pace("pace"),
    retrace("retrace"),
    hrZone("hrZone"),
    heightVsStart("heightVsStart"),
    climb("climb"),
    truePace("truePace"),
    avgPace("avgPace"),
    ;

    companion object {
        /** The default: the old km line plus what a hilly out-and-back needs. Metrics with no data are skipped. */
        val DEFAULT: Set<CheckInMetric> = entries.toSet()

        fun parse(keys: Collection<String?>): Set<CheckInMetric> {
            val byKey = entries.associateBy { it.key }
            return keys.mapNotNull { byKey[it] }.toSet()
        }
    }
}

/**
 * The check-in chosen in settings. [zoneBottomsBpm] = the bottoms of zones 2..5 by the user's own HR
 * method (null: no zones, so no HR line). Only a live (non-replay) Free or Trail run gets one; with
 * none, the km line is the legacy [LiveWords.kmSplit] word for word.
 */
data class CheckInPlan(val metrics: Set<CheckInMetric>, val zoneBottomsBpm: List<Double>? = null) {
    init {
        require(zoneBottomsBpm == null || zoneBottomsBpm.size == 4) { "zoneBottomsBpm is zones 2..5" }
    }
}

/** Everything the words need at a km mark; a null field = no data, and its metric is skipped. */
data class CheckInSnapshot(
    val avgPaceSecPerKm: Double? = null,
    /** This km's True pace over its raw pace (hills and heat out, the run screen's TRUE pace); null = unknown. */
    val kmTrueFactor: Double? = null,
    val hrZone: Int? = null,
    /** Active ms spent in [hrZone] this run; null after a restore (the earlier minutes were not seen). */
    val hrZoneMs: Long? = null,
    val climbM: Double? = null,
    val heightVsStartM: Double? = null,
    /** Retrace: distance back to the start along the way out, km; null when not retracing. */
    val backToStartKm: Double? = null,
    val climbAheadM: Double? = null,
)

/**
 * Feeds the check-in from the 1 Hz tick: zone time, a distance-weighted True/raw pace factor per km,
 * the start height. Only ticks the run is recording and not auto-paused are offered, so pauses count
 * for nothing. Pure and JVM-tested.
 */
class CheckInTracker(private val zoneBottomsBpm: List<Double>?) {
    private val hrWindow = ArrayDeque<Double>()
    private val zoneMs = LongArray(6)
    private var kmDist = 0.0
    private var kmFactorW = 0.0
    private var startElevationM: Double? = null

    /** Set after a restore: the zone minutes before the kill were not seen, so only the zone is said. */
    var partial: Boolean = false

    /** One recording tick of [dtMs]: [distDeltaM] moved, [pace] raw and [truePace] (s/km), [hr] null when stale or no strap. */
    fun tick(dtMs: Long, distDeltaM: Double, pace: Double?, truePace: Double?, hr: Double?) {
        if (distDeltaM > 0 && pace != null && truePace != null && pace > 0) {
            kmDist += distDeltaM
            kmFactorW += distDeltaM * (truePace / pace)
        }
        if (hr != null && hr > 0) {
            hrWindow.addLast(hr)
            while (hrWindow.size > HR_WINDOW) hrWindow.removeFirst()
        } else if (hrWindow.isNotEmpty()) {
            // A dropped strap ages the window out instead of freezing the last zone.
            hrWindow.removeFirst()
        }
        smoothedZone()?.let { zoneMs[it] += dtMs }
    }

    /**
     * The first absolute height seen while recording on the barometer; later heights are read against it.
     * A GPS reading never becomes the start (GPS altitude can be off by tens of metres, and the barometer
     * may only arrive later), so a run that starts on GPS takes its baseline when the barometer lands.
     */
    fun noteElevation(m: Double?, baro: Boolean) {
        if (baro && m != null && startElevationM == null) startElevationM = m
    }

    /**
     * The extra metrics at a km mark: [activeMs] / [distM] = the run so far, [baro] = the run's elevation source is the
     * barometer (height and climb are skipped otherwise), [elevationM] / [ascentM] = the live elevation. Closes the km's
     * True-pace factor, so call it once per km.
     */
    fun snapshot(activeMs: Long, distM: Double, baro: Boolean, elevationM: Double?, ascentM: Double?): CheckInSnapshot {
        val zone = smoothedZone()
        return CheckInSnapshot(
            avgPaceSecPerKm = if (distM >= 100 && activeMs > 0) activeMs / 1_000.0 / (distM / 1_000.0) else null,
            kmTrueFactor = closeKmFactor(),
            hrZone = zone,
            hrZoneMs = zone?.let { z -> zoneMsOf(z).takeIf { !partial } },
            climbM = if (baro) ascentM else null,
            heightVsStartM = if (baro) heightVsStart(elevationM) else null,
        )
    }

    fun heightVsStart(m: Double?): Double? = m?.let { e -> startElevationM?.let { e - it } }

    /** The zone of the mean HR over the last [HR_WINDOW] s; null with under [MIN_HR] readings (no strap, stale). */
    fun smoothedZone(): Int? {
        val bottoms = zoneBottomsBpm ?: return null
        if (hrWindow.size < MIN_HR) return null
        val mean = hrWindow.average()
        return (5 downTo 2).firstOrNull { mean >= bottoms[it - 2] } ?: 1
    }

    fun zoneMsOf(zone: Int): Long = zoneMs[zone]

    /** This km's True/raw pace factor; reset by the call, so each km stands alone. Null with under [MIN_KM_DIST] seen. */
    fun closeKmFactor(): Double? {
        val f = if (kmDist >= MIN_KM_DIST) kmFactorW / kmDist else null
        kmDist = 0.0
        kmFactorW = 0.0
        return f
    }

    companion object {
        const val HR_WINDOW = 30
        const val MIN_HR = 10
        const val MIN_KM_DIST = 200.0
    }
}

/** The words of the check-in: plain, casual, no em dashes. */
object CheckInWords {
    /** The extras after the km line stop at this many words (about 7 s): a check-in is a glance, not a report. */
    const val MAX_EXTRA_WORDS = 18

    /** Climb under this is a flat run: not worth a line. */
    const val MIN_CLIMB_M = 15.0

    /** Within this of the start height is "level", not said. */
    const val MIN_HEIGHT_M = 5.0

    /** True pace is only said when hills or heat move it this far from the raw pace. */
    const val MIN_TRUE_DIFF_SEC = 5.0

    /**
     * [base]: the km line, built from the chosen distance / time / pace parts; with all three it is
     * exactly [LiveWords.kmSplit]. [tail]: the extras in importance order, cut to [MAX_EXTRA_WORDS].
     */
    data class Spoken(val base: String?, val tail: String?)

    fun build(plan: CheckInPlan, km: Int, activeMs: Long, splitMs: Long?, snap: CheckInSnapshot?): Spoken {
        val m = plan.metrics
        val parts = ArrayList<String>()
        if (CheckInMetric.distance in m) parts.add("$km k")
        if (CheckInMetric.time in m) parts.add(LiveWords.duration(activeMs))
        val splitPace = splitMs?.takeIf { it > 0 }
        if (CheckInMetric.pace in m && splitPace != null) parts.add("pace ${CueWords.clock(splitPace.toDouble())}")
        val base = if (parts.isEmpty()) null else parts.joinToString(", ") + "."
        val extras = ArrayList<String>()
        if (snap != null) {
            if (CheckInMetric.retrace in m) retrace(snap)?.let { extras.add(it) }
            if (CheckInMetric.hrZone in m) hrZone(snap)?.let { extras.add(it) }
            if (CheckInMetric.heightVsStart in m) height(snap)?.let { extras.add(it) }
            if (CheckInMetric.climb in m) snap.climbM?.takeIf { it >= MIN_CLIMB_M }?.let { extras.add("Climbed ${metres(it)}.") }
            if (CheckInMetric.truePace in m) truePace(snap, splitPace)?.let { extras.add(it) }
            if (CheckInMetric.avgPace in m) snap.avgPaceSecPerKm?.takeIf { it > 0 }?.let { extras.add("Average ${CueWords.clock(it * 1_000)}.") }
        }
        var words = 0
        val kept = ArrayList<String>()
        for (e in extras) {
            val w = CueComposer.words(e)
            if (words + w > MAX_EXTRA_WORDS) break
            kept.add(e)
            words += w
        }
        val tail = kept.joinToString(" ").ifEmpty { null }
        // Nothing chosen for the km line: the extras lead, as the line itself.
        return if (base == null) Spoken(tail, null) else Spoken(base, tail)
    }

    private fun retrace(s: CheckInSnapshot): String? {
        val back = s.backToStartKm ?: return null
        val km = "${tenths(back)} k back to the start"
        val climb = s.climbAheadM?.takeIf { it >= MIN_CLIMB_M }
        return if (climb != null) "$km, ${metres(climb)} of climb ahead." else "$km."
    }

    private fun hrZone(s: CheckInSnapshot): String? {
        val z = s.hrZone ?: return null
        val ms = s.hrZoneMs?.takeIf { it >= 60_000 } ?: return "Zone $z."
        val min = (ms / 60_000.0).roundToLong()
        return "Zone $z for $min ${if (min == 1L) "minute" else "minutes"}."
    }

    private fun height(s: CheckInSnapshot): String? {
        val h = s.heightVsStartM ?: return null
        if (abs(h) < MIN_HEIGHT_M) return null
        return "${metres(abs(h))} ${if (h > 0) "above" else "below"} the start."
    }

    /** True pace is said only when it differs from this km's raw pace by [MIN_TRUE_DIFF_SEC]: a flat km already said it. */
    private fun truePace(s: CheckInSnapshot, rawMs: Long?): String? {
        val factor = s.kmTrueFactor ?: return null
        val raw = rawMs?.let { it / 1_000.0 } ?: return null
        val tp = raw * factor
        if (abs(tp - raw) < MIN_TRUE_DIFF_SEC) return null
        return "True pace ${CueWords.clock(tp * 1_000)}."
    }

    /** Whole metres, to the nearest 5 from 20 up ("85 metres", not "83"). */
    internal fun metres(m: Double): String {
        val n = if (m >= 20) ((m / 5).roundToInt() * 5) else m.roundToInt()
        return "$n ${if (n == 1) "metre" else "metres"}"
    }

    private fun tenths(km: Double): String {
        val t = (km * 10).roundToInt()
        return if (t % 10 == 0) "${t / 10}" else "${t / 10} point ${t % 10}"
    }
}
