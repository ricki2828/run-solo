package app.runsolo.core.record

import app.runsolo.core.live.CueComposer
import app.runsolo.core.model.RunMode
import app.runsolo.core.model.SessionSpec
import app.runsolo.core.model.TargetKind
import app.runsolo.core.model.Units
import kotlin.math.roundToInt
import kotlin.math.roundToLong

/**
 * The spoken summaries at the start and end of a run (founder 3 Oct): plain, casual, no em
 * dashes, units-aware. Kept out of the Android `CuePlayer` so the wording is JVM-tested
 * (`VoiceCopyFixture`). Null = nothing to say.
 */
object SummaryWords {
    const val RUN_SAVED = "Run saved"

    /** A climb under this is not worth saying at the end of a run. */
    const val MIN_CLIMB_M = 20.0

    private const val M_PER_MI = 1_609.344
    private const val FT_PER_M = 3.28084

    /**
     * What the run is, as it starts. A route with a name is "Following Kastro loop, 6.2 kilometres,
     * 230 metres of climb" (climb only with elevation); when that would not fit the 16-word cue
     * budget the climb goes first, then the distance, then the name.
     */
    fun start(
        mode: RunMode,
        spec: SessionSpec?,
        units: Units,
        routeName: String? = null,
        routeM: Double? = null,
        routeClimbM: Double? = null,
    ): String? {
        val miles = units == Units.mi
        return when (mode) {
            RunMode.trail -> {
                val name = routeName?.let { speakable(it) }
                if (routeName == null) return "Trail run."
                val dist = routeM?.takeIf { it > 0 }?.let { distance(it, miles, hundredths = false) }
                val climb = routeClimbM?.takeIf { it > 0 }?.let { height(it, miles, step = true) + " of climb" }
                val tries = listOf(
                    listOfNotNull(name, dist, climb),
                    listOfNotNull(name, dist),
                    listOfNotNull(name),
                )
                for (parts in tries) {
                    val text = "Trail run. Following ${parts.joinToString(", ")}."
                    if (CueComposer.words(text) <= CueComposer.MAX_WORDS) return text
                }
                "Trail run. Following a route."
            }
            else -> when {
                spec?.isEvent == true -> "${spec.spoken}."
                spec?.isGoal == true -> "Free run. Goal: ${goal(spec, miles)}."
                mode == RunMode.intervals -> spec?.let { if (it.templateId == SessionSpec.NORWEGIAN_4X4_ID) "${it.spoken}. Warm up as long as you like." else "${it.spoken}." }
                mode == RunMode.cooper -> "Cooper test."
                mode == RunMode.laps -> "Laps run."
                else -> "Free run."
            }
        }
    }

    /** A route name as TTS should read it: no URLs, emoji or dashes, one line, at most [MAX_NAME] characters; "a route" when nothing is left. */
    fun speakable(raw: String): String {
        var s = raw.replace(Regex("""(https?://|www\.)\S+"""), " ")
        s = s.replace(Regex("[\\u2012-\\u2015\\u2212_]"), " ").replace(" - ", " ").replace("-", " ")
        s = s.filter { it.isLetterOrDigit() || it == ' ' || it == '\'' || it == '.' || it == ',' || it == '&' }
        s = s.replace("&", " and ").replace(Regex("\\s+"), " ").trim().trim('.', ',').trim()
        if (s.length > MAX_NAME) s = s.take(MAX_NAME).substringBeforeLast(' ', s.take(MAX_NAME)).trim()
        return s.ifEmpty { "a route" }
    }

    private const val MAX_NAME = 40

    private fun goal(spec: SessionSpec, miles: Boolean): String {
        val step = spec.steps.first()
        return if (step.target == TargetKind.distance) distance(step.value.toDouble(), miles, hundredths = false) else duration(step.value * 1_000L, seconds = false)
    }

    /**
     * What the run came to: distance, time, average pace, and the climb when it is [MIN_CLIMB_M]
     * or more; then [verdict] (the result screen's own words) when there is one. Null when there is
     * no distance to speak of (indoor, GPS never came). Always opens with "Run saved.".
     */
    fun end(distanceM: Double, timeMs: Long, units: Units, climbM: Double? = null, verdict: String? = null, withPace: Boolean = true): String {
        val line = verdict?.trim()?.takeIf { it.isNotEmpty() }
        if (distanceM < 10 || timeMs <= 0) return if (line == null) "$RUN_SAVED." else "$RUN_SAVED. $line"
        val miles = units == Units.mi
        val unitM = if (miles) M_PER_MI else 1_000.0
        val parts = ArrayList<String>()
        parts.add(distance(distanceM, miles, hundredths = true))
        parts.add(duration(timeMs, seconds = true))
        val paceS = (timeMs / 1_000.0) / (distanceM / unitM)
        if (withPace && distanceM >= 100 && paceS.isFinite()) parts.add("${minutesSeconds(paceS.roundToLong())} per ${if (miles) "mile" else "kilometre"}")
        if (climbM != null && climbM >= MIN_CLIMB_M) parts.add(height(climbM, miles, step = false) + " of climb")
        val stats = parts.joinToString(", ") + "."
        return if (line == null) "$RUN_SAVED. $stats" else "$RUN_SAVED. $stats $line"
    }

    /**
     * The stop cue's words. With the spoken summary on, the end line opens with "Run saved." (one voice,
     * nothing to cut off), so the stop cue itself is silent (it still buzzes); with it off, "Run saved".
     */
    fun stopCue(spokenSummaryOn: Boolean): String? = if (spokenSummaryOn) null else RUN_SAVED

    /** "6.2 kilometres" / "1 kilometre" / "800 metres" (start), "5 kilometres 20" (end, hundredths, 5.05 is "5 kilometres oh 5"). */
    fun distance(m: Double, miles: Boolean, hundredths: Boolean): String {
        val unit = if (miles) "mile" else "kilometre"
        val perUnit = if (miles) M_PER_MI else 1_000.0
        if (!miles && m < 1_000) return plural(((m / 10).roundToInt() * 10).coerceAtLeast(10), "metre")
        if (miles && m < perUnit / 10) return plural((m * FT_PER_M / 10).roundToInt() * 10, "foot", "feet")
        if (hundredths) {
            val total = (m / perUnit * 100).roundToInt()
            val whole = total / 100
            val rest = total % 100
            val head = plural(whole, unit)
            return when {
                rest == 0 -> head
                rest < 10 -> "$head oh $rest"
                else -> "$head $rest"
            }
        }
        val tenths = (m / perUnit * 10).roundToInt()
        return if (tenths % 10 == 0) plural(tenths / 10, unit) else "${tenths / 10}.${tenths % 10} ${unit}s"
    }

    /** "41 minutes", "41 minutes 12", "1 hour 5 minutes", "45 seconds". [seconds] false drops the seconds (a goal). */
    fun duration(ms: Long, seconds: Boolean): String {
        val s = (ms / 1_000.0).roundToLong()
        val h = s / 3_600
        val m = (s % 3_600) / 60
        val sec = s % 60
        return when {
            h > 0 -> if (m == 0L) plural(h.toInt(), "hour") else "${plural(h.toInt(), "hour")} ${plural(m.toInt(), "minute")}"
            m == 0L -> plural(sec.toInt(), "second")
            sec == 0L || !seconds -> plural(m.toInt(), "minute")
            else -> "${plural(m.toInt(), "minute")} $sec"
        }
    }

    /** "4 minutes 45", "5 minutes", "45 seconds". */
    private fun minutesSeconds(s: Long): String {
        val m = s / 60
        val sec = s % 60
        return when {
            m == 0L -> plural(sec.toInt(), "second")
            sec == 0L -> plural(m.toInt(), "minute")
            else -> "${plural(m.toInt(), "minute")} $sec"
        }
    }

    /** Climb in metres or, with miles, feet; [step] rounds to 5 (under 100) or 10 so a plan figure does not sound exact. */
    private fun height(m: Double, miles: Boolean, step: Boolean): String {
        val v = if (miles) m * FT_PER_M else m
        val n = if (step) {
            val unit = if (v >= 100) 10 else 5
            ((v / unit).roundToInt() * unit).coerceAtLeast(unit)
        } else v.roundToInt()
        return if (miles) plural(n, "foot", "feet") else plural(n, "metre")
    }

    private fun plural(n: Int, one: String, many: String = "${one}s"): String = if (n == 1) "1 $one" else "$n $many"
}
