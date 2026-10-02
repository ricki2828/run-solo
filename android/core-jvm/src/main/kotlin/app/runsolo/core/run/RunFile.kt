package app.runsolo.core.run

import app.runsolo.core.elevation.ElevSource
import app.runsolo.core.elevation.ElevationFuser
import app.runsolo.core.gps.PointFilter
import app.runsolo.core.journal.JournalLine
import app.runsolo.core.journal.Replay
import app.runsolo.core.journal.RunEvent
import app.runsolo.core.json.Json
import app.runsolo.core.model.LapKind
import app.runsolo.core.model.LapSource
import app.runsolo.core.model.LocationFix
import app.runsolo.core.model.RunMode
import app.runsolo.core.model.SessionSpec
import app.runsolo.core.model.Units
import java.io.ByteArrayOutputStream
import java.time.Instant
import java.util.zip.GZIPInputStream
import java.util.zip.GZIPOutputStream

/**
 * Schema v5 run file (plan §4, §18.7; Phase 3 §3.8: `mode` `intervals` replaces `fourByFour`, `session`
 * replaces `preset`), built from a journal replay. All `t` are run-timeline millis
 * since `start`; `d` values are cumulative accepted-haversine metres.
 *
 * Laps are the segments between lap markers: `[start, m1], [m1, m2], …, [mn, end]`. A lap's
 * `kind` is the kind of the marker that ENDS it (auto for a cue-driven lap, manual otherwise);
 * the final segment, ended by Stop, is `manual`. Pauses do not cut laps — they are listed in
 * `pauses` and the engine reads them from there. `kind = pause` is reserved and unused in v1.
 *
 * A `pauses` entry is `[t0, t1]` for a pause the runner made and `[t0, t1, "auto"]` for one the
 * recorder made when the runner stopped (the array in memory is `[t0, t1, 1]`, see [isAutoPause]);
 * every file written before auto-pause has only the two-element form, which is still a manual pause.
 *
 * Schema 5 (elevation): a sample may carry a ninth element, the fused elevation in metres
 * ([ElevationFuser]), present only when there is one; `elev_src` (`baro` or `gps`) says which sensor
 * it mostly came from and is written only with at least one such sample. A run with no elevation is
 * byte-for-byte what schema 4 wrote, but for the version.
 */
data class RunFile(
    val id: String,
    val device: String,
    val app: String,
    val startEpochMs: Long,
    val endEpochMs: Long,
    val tz: String,
    val mode: RunMode,
    val session: SessionSpec?,
    val units: Units,
    val laps: List<Lap>,
    val pauses: List<LongArray>,
    val gaps: List<LongArray>,
    val samples: List<Sample>,
    /**
     * The nudges spoken this run (`cue_fired` nudge lines, rule to km or rep), in journal order.
     * The engine blocks them on the next run of the board (CR1). Written as `nudges_fired` only
     * when there are some, so a run without nudges is byte-for-byte the schema 3 it always was.
     */
    val nudgesFired: List<Pair<String, Int>> = emptyList(),
    /** Where the samples' [Sample.elevM] came from; null when no sample has one. */
    val elevSrc: ElevSource? = null,
) {
    data class Lap(val i: Int, val t0: Long, val t1: Long, val d0: Double, val d1: Double, val kind: LapKind)

    /** lat/lon/accuracy null = no fix at that tick; `distM` then repeats the last value. */
    data class Sample(
        val t: Long,
        val lat: Double?,
        val lon: Double?,
        val altM: Double?,
        val accuracyM: Double?,
        val speedMps: Double?,
        val distM: Double,
        val hr: Int?,
        /** Fused barometer + GPS elevation, metres; null = none at this tick. */
        val elevM: Double? = null,
    ) {
        val hasFix: Boolean get() = lat != null && lon != null && accuracyM != null
    }

    val fixCount: Int get() = samples.count { it.hasFix }

    val distanceM: Double get() = samples.lastOrNull()?.distM ?: 0.0
    val elapsedMs: Long get() = endEpochMs - startEpochMs

    fun toJson(): Map<String, Any?> = linkedMapOf(
        "schema" to SCHEMA,
        "id" to id,
        "device" to device,
        "app" to app,
        "start" to Instant.ofEpochMilli(startEpochMs).toString(),
        "end" to Instant.ofEpochMilli(endEpochMs).toString(),
        "tz" to tz,
        "mode" to mode.name,
        "session" to session?.toJson(),
        "units" to units.name,
        "laps" to laps.map {
            linkedMapOf("i" to it.i, "t0" to it.t0, "t1" to it.t1, "d0" to it.d0, "d1" to it.d1, "kind" to it.kind.name)
        },
        "pauses" to pauses.map { if (isAutoPause(it)) listOf(it[0], it[1], AUTO_PAUSE_KIND) else it.asList() },
        "gaps" to gaps.map { it.asList() },
        "samples" to samples.map {
            val row = listOf(it.t, it.lat, it.lon, it.altM, it.accuracyM, it.speedMps, it.distM, it.hr)
            if (it.elevM == null) row else row + (Math.round(it.elevM * 10) / 10.0)
        },
    ).apply {
        if (elevSrc != null) put("elev_src", elevSrc.wire)
        if (nudgesFired.isNotEmpty()) put("nudges_fired", nudgesFired.map { listOf(it.first, it.second) })
    }

    fun toGzipBytes(): ByteArray {
        val out = ByteArrayOutputStream()
        GZIPOutputStream(out).use { it.write(Json.write(toJson()).toByteArray(Charsets.UTF_8)) }
        return out.toByteArray()
    }

    companion object {
        const val SCHEMA = 5

        /** The third element of an auto-pause entry in the file's `pauses`. */
        const val AUTO_PAUSE_KIND = "auto"

        /** A `pauses` entry made by auto-pause: three elements, `[t0, t1, 1]`. */
        fun isAutoPause(span: LongArray): Boolean = span.size > 2

        private fun pauseSpan(t0: Long, t1: Long, auto: Boolean) = if (auto) longArrayOf(t0, t1, 1) else longArrayOf(t0, t1)

        /**
         * Builds the run file from a replay; distance is recomputed by [PointFilter] over raw
         * samples. A run stopped (or killed) while paused ends at the pause: the finish screen's
         * tap pauses, SAVE stops, and the time spent on that screen is not part of the run, so the
         * end, the last lap and the samples stop at the pause and no trailing pause is written.
         */
        fun fromReplay(r: Replay, endEpochMs: Long): RunFile {
            val h: JournalLine.Header = r.header
            val filter = PointFilter()
            val fuser = ElevationFuser()
            val samples = ArrayList<Sample>()
            val markers = ArrayList<Pair<Long, LapKind>>()
            val pauses = ArrayList<LongArray>()
            val gaps = ArrayList<LongArray>()
            // One contiguous paused stretch can start as an auto-pause and be taken over by a manual
            // PAUSE (the finish screen's tap): [pauseStart] is where the stretch began, [autoStart] where
            // the auto part began (null once manual), [manualStart] where the manual part did.
            var pauseStart: Long? = null
            var autoStart: Long? = null
            var manualStart: Long? = null
            for (e in r.events) {
                when (e) {
                    is RunEvent.Sample -> {
                        // Paused (either kind): journaled, not measured (distance is frozen). A manual pause
                        // re-anchors the filter on resume; an auto-pause does not, so the ground covered
                        // before the recorder noticed the runner moving again still counts.
                        // Engine contract: samples strictly increasing in t (a clamped clock jump or a
                        // duplicate fix would repeat a t → dropped), hr > 0 or null.
                        val last = samples.lastOrNull()
                        if (last != null && e.t <= last.t) continue
                        if (e.hasFix && pauseStart == null) filter.offer(LocationFix(e.t, e.lat!!, e.lon!!, e.altM, e.accuracyM!!, e.speedMps))
                        val hr = e.hr?.takeIf { it > 0 }
                        // Elevation runs through every sample, paused or not, so the level stays right on resume.
                        val elev = fuser.offer(e.t, e.hpa, e.altM, e.accuracyM)
                        samples.add(Sample(e.t, e.lat, e.lon, e.altM, e.accuracyM, e.speedMps, filter.totalM, hr, elev))
                    }
                    is RunEvent.Lap -> markers.add(e.t to if (e.source == LapSource.auto) LapKind.auto else LapKind.manual)
                    is RunEvent.Pause -> {
                        if (pauseStart == null) pauseStart = e.t
                        autoStart?.let { pauses.add(pauseSpan(it, e.t, auto = true)) }
                        autoStart = null
                        if (manualStart == null) manualStart = e.t
                    }
                    is RunEvent.AutoPause -> if (pauseStart == null) {
                        pauseStart = e.t
                        autoStart = e.t
                    }
                    is RunEvent.Resume, is RunEvent.AutoResume -> if (pauseStart != null) {
                        autoStart?.let { pauses.add(pauseSpan(it, e.t, auto = true)) }
                        manualStart?.let {
                            pauses.add(pauseSpan(it, e.t, auto = false))
                            filter.reanchor()
                        }
                        pauseStart = null
                        autoStart = null
                        manualStart = null
                    }
                    is RunEvent.Gap -> gaps.add(longArrayOf(e.t, e.endT))
                    is RunEvent.Cue, is RunEvent.HrLink -> Unit
                }
            }
            // Still paused at stop / kill: the run ends where it paused.
            val endT = pauseStart ?: r.endT
            pauseStart?.let { p ->
                samples.removeAll { it.t > p }
                pauses.removeAll { it[0] >= p } // an auto part a PAUSE took over: the run ends at its start, no span
                gaps.removeAll { it[0] >= p }
            }
            // The samples hold the fuser's relative series; the level GPS settled on makes it absolute for
            // every tick, the first seconds included. No level (never a usable GPS altitude): no elevation.
            val level = fuser.levelM
            for (i in samples.indices) {
                val e = samples[i].elevM ?: continue
                samples[i] = samples[i].copy(elevM = level?.let { e + it })
            }
            val laps = ArrayList<Lap>()
            var t0 = 0L
            var d0 = 0.0
            for ((t, kind) in markers) {
                val d = distanceAt(samples, t)
                laps.add(Lap(laps.size, t0, t, d0, d, kind))
                t0 = t
                d0 = d
            }
            laps.add(Lap(laps.size, t0, endT, d0, samples.lastOrNull()?.distM ?: filter.totalM, LapKind.manual))
            return RunFile(
                id = h.id, device = h.device, app = h.app,
                startEpochMs = h.w, endEpochMs = endEpochMs - (r.endT - endT), tz = h.tz,
                mode = h.mode, session = h.session, units = h.units,
                laps = laps, pauses = pauses, gaps = gaps, samples = samples,
                nudgesFired = r.cuesFired
                    .filter { it.kind == JournalLine.FiredKind.nudge }
                    .map { it.key to it.index }
                    .distinct(),
                elevSrc = if (samples.any { it.elevM != null }) fuser.source else null,
            )
        }

        /**
         * Cumulative distance at [t], linearly interpolated between the samples around it and
         * clamped to the ends: the engine's `Trace.distAt` and the live LapEvent's distance. (It
         * used to take the last sample at or before [t], which read every lap up to a sample
         * short: 399.55 m for a 400 m auto lap.)
         */
        internal fun distanceAt(samples: List<Sample>, t: Long): Double {
            if (samples.isEmpty()) return 0.0
            if (t <= samples.first().t) return samples.first().distM
            if (t >= samples.last().t) return samples.last().distM
            var lo = 0
            var hi = samples.size - 1
            while (hi - lo > 1) {
                val mid = (lo + hi) ushr 1
                if (samples[mid].t <= t) lo = mid else hi = mid
            }
            val a = samples[lo]
            val b = samples[hi]
            if (a.t == t) return a.distM
            return a.distM + (b.distM - a.distM) * (t - a.t).toDouble() / (b.t - a.t)
        }

        /** Decodes a gzip'd run file back to its JSON map (used by tests and the reconciler's sanity read). */
        fun readJson(gz: ByteArray): Map<String, Any?> =
            Json.parseObject(GZIPInputStream(gz.inputStream()).readBytes().toString(Charsets.UTF_8))
    }
}
