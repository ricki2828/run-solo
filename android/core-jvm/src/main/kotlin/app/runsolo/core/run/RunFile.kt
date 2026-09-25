package app.runsolo.core.run

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
 * Schema v3 run file (plan §4, §18.7; Phase 3 §3.8: `mode` `intervals` replaces `fourByFour`, `session`
 * replaces `preset`), built from a journal replay. All `t` are run-timeline millis
 * since `start`; `d` values are cumulative accepted-haversine metres.
 *
 * Laps are the segments between lap markers: `[start, m1], [m1, m2], …, [mn, end]`. A lap's
 * `kind` is the kind of the marker that ENDS it (auto for a cue-driven lap, manual otherwise);
 * the final segment, ended by Stop, is `manual`. Pauses do not cut laps — they are listed in
 * `pauses` and the engine reads them from there. `kind = pause` is reserved and unused in v1.
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
        "pauses" to pauses.map { it.asList() },
        "gaps" to gaps.map { it.asList() },
        "samples" to samples.map { listOf(it.t, it.lat, it.lon, it.altM, it.accuracyM, it.speedMps, it.distM, it.hr) },
    )

    fun toGzipBytes(): ByteArray {
        val out = ByteArrayOutputStream()
        GZIPOutputStream(out).use { it.write(Json.write(toJson()).toByteArray(Charsets.UTF_8)) }
        return out.toByteArray()
    }

    companion object {
        const val SCHEMA = 3

        /** Builds the run file from a replay; distance is recomputed by [PointFilter] over raw samples. */
        fun fromReplay(r: Replay, endEpochMs: Long): RunFile {
            val h: JournalLine.Header = r.header
            val filter = PointFilter()
            val samples = ArrayList<Sample>()
            val markers = ArrayList<Pair<Long, LapKind>>()
            val pauses = ArrayList<LongArray>()
            val gaps = ArrayList<LongArray>()
            var pauseStart: Long? = null
            for (e in r.events) {
                when (e) {
                    is RunEvent.Sample -> {
                        // Paused: journaled, not measured (distance is frozen; the filter re-anchors on resume).
                        // Engine contract: samples strictly increasing in t (a clamped clock jump or a
                        // duplicate fix would repeat a t → dropped), hr > 0 or null.
                        val last = samples.lastOrNull()
                        if (last != null && e.t <= last.t) continue
                        if (e.hasFix && pauseStart == null) filter.offer(LocationFix(e.t, e.lat!!, e.lon!!, e.altM, e.accuracyM!!, e.speedMps))
                        val hr = e.hr?.takeIf { it > 0 }
                        samples.add(Sample(e.t, e.lat, e.lon, e.altM, e.accuracyM, e.speedMps, filter.totalM, hr))
                    }
                    is RunEvent.Lap -> markers.add(e.t to if (e.source == LapSource.auto) LapKind.auto else LapKind.manual)
                    is RunEvent.Pause -> if (pauseStart == null) pauseStart = e.t
                    is RunEvent.Resume -> pauseStart?.let {
                        pauses.add(longArrayOf(it, e.t))
                        pauseStart = null
                        filter.reanchor()
                    }
                    is RunEvent.Gap -> gaps.add(longArrayOf(e.t, e.endT))
                    is RunEvent.Cue, is RunEvent.HrLink -> Unit
                }
            }
            val endT = r.endT
            pauseStart?.let { pauses.add(longArrayOf(it, endT)) } // still paused at kill/stop
            val laps = ArrayList<Lap>()
            var t0 = 0L
            var d0 = 0.0
            for ((t, kind) in markers) {
                val d = distanceAt(samples, t)
                laps.add(Lap(laps.size, t0, t, d0, d, kind))
                t0 = t
                d0 = d
            }
            laps.add(Lap(laps.size, t0, endT, d0, filter.totalM, LapKind.manual))
            return RunFile(
                id = h.id, device = h.device, app = h.app,
                startEpochMs = h.w, endEpochMs = endEpochMs, tz = h.tz,
                mode = h.mode, session = h.session, units = h.units,
                laps = laps, pauses = pauses, gaps = gaps, samples = samples,
            )
        }

        private fun distanceAt(samples: List<Sample>, t: Long): Double {
            var d = 0.0
            for (s in samples) {
                if (s.t > t) break
                d = s.distM
            }
            return d
        }

        /** Decodes a gzip'd run file back to its JSON map (used by tests and the reconciler's sanity read). */
        fun readJson(gz: ByteArray): Map<String, Any?> =
            Json.parseObject(GZIPInputStream(gz.inputStream()).readBytes().toString(Charsets.UTF_8))
    }
}
