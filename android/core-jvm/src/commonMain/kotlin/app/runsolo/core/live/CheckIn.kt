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
data class CheckInPlan(
    val metrics: Set<CheckInMetric>,
    val zoneBottomsBpm: List<Double>? = null,
    /** Settings → Voice → "Voice detail". The default keeps today's check-in; the app and the prefs always say which. */
    val level: VoiceLevel = VoiceLevel.everything,
) {
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
    /**
     * Trail ghost: seconds ahead of the runner's best at this point (negative = behind); null = no ghost. The ghost
     * stream fills it; until then the Coach km line has no gap lead and the half km no gap item.
     */
    val ghostAheadSec: Double? = null,
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

/**
 * The Coach and Minimal km lines (cadence v1): a glance, not a report. "4 k. 31 minutes 12. pace 7:48." is 7 words
 * (2.6 s) against today's 25. One lead item at most, then the screen holds the rest.
 */
object CoachWords {
    /** A Coach km line is this many words at most (about 3.4 s); a board compare as the lead may take [MAX_WORDS_WITH_COMPARE]. */
    const val MAX_WORDS = 9
    const val MAX_WORDS_WITH_COMPARE = 12

    /** A trail km with at least this much gain is a hill: its pace says little, so it is left to the screen. */
    const val FLAT_KM_GAIN_M = 10.0

    /** Gaps under this are "level": no news. */
    const val MIN_GAP_SEC = 2.0

    /** "Minimal": the km word and nothing else; no km line at all when the check-in is switched off. */
    fun minimal(plan: CheckInPlan, km: Int): CheckInWords.Spoken =
        CheckInWords.Spoken(if (plan.metrics.isEmpty()) null else "$km k.", null)

    /**
     * The Coach km line. [compare]: a spoken board compare (Free runs), which is then the one lead. [trail]: a Trail run.
     * [kmGainM]: this km's climb (barometer), null = unknown. Lead, first that is true: the compare, the ghost gap,
     * the km pace on a Free/road km (or a trail km under [FLAT_KM_GAIN_M] gain); else none. Over [MAX_WORDS] the time
     * goes first (it is on the screen), then the lead.
     */
    fun km(plan: CheckInPlan, km: Int, activeMs: Long, splitMs: Long?, snap: CheckInSnapshot?, trail: Boolean, kmGainM: Double?, compare: String?): CheckInWords.Spoken {
        val m = plan.metrics
        if (m.isEmpty()) return CheckInWords.Spoken(null, null)
        val dist = if (CheckInMetric.distance in m) "$km k." else null
        val time = if (CheckInMetric.time in m) "${LiveWords.duration(activeMs)}." else null
        val splitPace = splitMs?.takeIf { it > 0 }
        fun line(t: String?, l: String?): String? = listOfNotNull(dist, t, l).joinToString(" ").ifEmpty { null }
        // A compare rides the cue itself (CueComposer) as the one lead, so the base is only what comes before it.
        if (compare != null) {
            val withTime = line(time, null)
            val fits = CueComposer.words(withTime) + CueComposer.words(compare) <= MAX_WORDS_WITH_COMPARE
            return CheckInWords.Spoken(if (fits) withTime else line(null, null), null)
        }
        val flatEnough = !trail || (kmGainM != null && kmGainM < FLAT_KM_GAIN_M)
        val lead: String? = snap?.ghostAheadSec?.let { gapLine(it) }
            ?: if (CheckInMetric.pace in m && splitPace != null && flatEnough) "pace ${CueWords.clock(splitPace.toDouble())}." else null
        var text = line(time, lead)
        if (CueComposer.words(text) > MAX_WORDS) text = line(null, lead)
        if (CueComposer.words(text) > MAX_WORDS) text = line(time, null)
        return CheckInWords.Spoken(text, null)
    }

    /** "12 up on your best." / "12 off your best."; null when level. */
    fun gapLine(aheadSec: Double): String? {
        val s = abs(aheadSec).roundToLong()
        if (abs(aheadSec) < MIN_GAP_SEC) return null
        return if (aheadSec > 0) "${CueWords.gap(s)} up on your best." else "${CueWords.gap(s)} off your best."
    }
}

/**
 * What the half km says: only news, else nothing. The first item that qualifies, in order: the ghost gap moved
 * 15 s since it was last said, the HR zone changed, 40 m more climb since last said, the height passed a 50 m
 * step, the average pace (Free only, every 2nd half km). Each item at most once per 1.5 km; the first sighting of
 * a figure is a baseline, not news. At most [MAX_WORDS] words. One per run; pure.
 */
class HalfKmNews {
    private var lastGap: Double? = null
    private var lastZone: Int? = null
    private var lastClimb = 0.0
    private var lastHeightStep = 0
    private var halves = 0
    private val itemAtM = HashMap<String, Double>()

    /** A whole km line said these; they are the baseline the half km measures change from. */
    fun noteKm(snap: CheckInSnapshot?) {
        if (snap?.ghostAheadSec != null && CoachWords.gapLine(snap.ghostAheadSec) != null) lastGap = snap.ghostAheadSec
    }

    fun line(plan: CheckInPlan, snap: CheckInSnapshot?, distM: Double, trail: Boolean): TalkLine? {
        halves++
        snap ?: return null
        val m = plan.metrics
        gap(snap, distM)?.let { return it }
        if (CheckInMetric.hrZone in m) zone(snap, distM)?.let { return it }
        if (CheckInMetric.climb in m) climb(snap, distM)?.let { return it }
        if (CheckInMetric.heightVsStart in m) height(snap, distM)?.let { return it }
        if (CheckInMetric.avgPace in m && !trail && halves % 2 == 0) avg(snap, distM)?.let { return it }
        return null
    }

    private fun due(item: String, distM: Double): Boolean = distM - (itemAtM[item] ?: Double.NEGATIVE_INFINITY) >= REPEAT_M

    private fun said(item: String, distM: Double, text: String, value: Double?, step: Double?): TalkLine {
        itemAtM[item] = distM
        return TalkLine(CueSlot.halfKm, "halfKm:$item", text, value, step)
    }

    private fun gap(s: CheckInSnapshot, distM: Double): TalkLine? {
        val g = s.ghostAheadSec ?: return null
        val last = lastGap
        if (last == null) {
            lastGap = g
            return null
        }
        if (abs(g - last) < GAP_STEP_SEC || !due("gap", distM)) return null
        val text = CoachWords.gapLine(g)?.takeIf { CueComposer.words(it) <= MAX_WORDS } ?: return null
        lastGap = g
        return said("gap", distM, text, g, GAP_STEP_SEC)
    }

    private fun zone(s: CheckInSnapshot, distM: Double): TalkLine? {
        val z = s.hrZone ?: return null
        val last = lastZone
        if (last == null) {
            lastZone = z
            return null
        }
        if (z == last || !due("zone", distM)) return null
        lastZone = z
        return said("zone", distM, "Zone $z.", z.toDouble(), 1.0)
    }

    private fun climb(s: CheckInSnapshot, distM: Double): TalkLine? {
        val c = s.climbM ?: return null
        if (c - lastClimb < CLIMB_STEP_M || !due("climb", distM)) return null
        lastClimb = c
        return said("climb", distM, "Climbed ${CheckInWords.metres(c)} so far.", c, CLIMB_STEP_M)
    }

    private fun height(s: CheckInSnapshot, distM: Double): TalkLine? {
        val h = s.heightVsStartM ?: return null
        val step = (h / HEIGHT_STEP_M).toInt()
        if (step == lastHeightStep || !due("height", distM)) return null
        lastHeightStep = step
        if (step == 0) return null
        return said("height", distM, "${CheckInWords.metres(abs(h))} ${if (h > 0) "above" else "below"} the start.", h, HEIGHT_STEP_M)
    }

    private fun avg(s: CheckInSnapshot, distM: Double): TalkLine? {
        val a = s.avgPaceSecPerKm?.takeIf { it > 0 } ?: return null
        if (!due("avg", distM)) return null
        return said("avg", distM, "Average ${CueWords.clock(a * 1_000)}.", a, 0.0)
    }

    companion object {
        const val MAX_WORDS = 6
        const val REPEAT_M = 1_500.0
        const val GAP_STEP_SEC = 15.0
        const val CLIMB_STEP_M = 40.0
        const val HEIGHT_STEP_M = 50.0
    }
}
