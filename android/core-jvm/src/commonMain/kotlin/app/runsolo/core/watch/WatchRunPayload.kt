package app.runsolo.core.watch

import app.runsolo.core.json.Json
import app.runsolo.core.model.LapKind
import app.runsolo.core.model.Units
import app.runsolo.core.run.RunFile

/**
 * A finished run as the Garmin watch sends it, reassembled from chunks by the transport layer (G4/G5) and
 * handed to [WatchRunImporter]. Pure data plus [parse]; nothing here touches storage.
 *
 * Wire form: a UTF-8 JSON object, [VERSION] 1. Rows reuse the run file's shapes so the importer maps them 1:1.
 * Key order, whitespace and number formatting are the sender's business; the parser takes any valid JSON.
 * ```
 * { "v": 1, "runId": "gw-<hex>", "model": "forerunner265", "appVersion": "0.1.0",
 *   "startEpochMs": .., "endEpochMs": .., "tz": "..", "units": "km", "mode": "free",
 *   "laps":   [{"i":0,"t0":..,"t1":..,"d0":..,"d1":..,"kind":"manual"}],
 *   "pauses": [[t0,t1] | [t0,t1,"auto"]],  "gaps": [[t0,t1]],
 *   "samples": [[t,lat?,lon?,altM?,accuracyM?,speedMps?,distM,hr?]],   // distM = the watch's elapsedDistance
 *   "rateChanges": [[atMs, rateS], ..],
 *   "coach": {"choice"?: "..", "cues": [[kind,km,tMs]], "prompts"?: [[trigger,[options],choice,source,km,openedMs,answeredMs]]} }
 * ```
 * Integers (times, indexes, counts) must be written as integers, not `5000.0`.
 *
 * **Integrity contract (whole payload).** The watch builds the JSON as a string, UTF-8 encodes it, and computes
 * CRC-32 over exactly those bytes: the algorithm is CRC-32/ISO-HDLC (the zlib/PNG/gzip CRC): reflected polynomial
 * 0xEDB88320, initial value 0xFFFFFFFF, final XOR 0xFFFFFFFF, bytes processed in order, no framing, no trailing
 * newline unless it is part of the bytes. The CRC travels outside the body (the transport envelope or final
 * chunk header) as an unsigned 32-bit value, and the receiver passes the reassembled bytes untouched together
 * with that value to [WatchRunImporter.import]. Check value: CRC-32("123456789") = 0xCBF43926.
 *
 * **Distance contract.** The last lap's `d1` equals the final sample's `distM` within [END_DISTANCE_TOLERANCE_M], so
 * the watch always sends a closing sample at stop. While `rateS` is 0 (no track) the watch sends a distance-only
 * sample (`lat`/`lon` null) at every whole km of `units` it crosses, within [KM_SAMPLE_TOLERANCE_M] of the mark,
 * and at every lap boundary; the phone derives km splits from those samples and the importer rejects a payload
 * that lacks one. A thinned stretch (`rateS` > 0) is covered by the track itself.
 */
data class WatchRunPayload(
    val runId: String,
    val model: String,
    val appVersion: String,
    val startEpochMs: Long,
    val endEpochMs: Long,
    val tz: String,
    val units: Units,
    val laps: List<RunFile.Lap>,
    /** Run-file pause spans; an auto-pause is `[t0, t1, 1]` in memory (see [RunFile.isAutoPause]). */
    val pauses: List<LongArray>,
    val gaps: List<LongArray>,
    val samples: List<RunFile.Sample>,
    val rateChanges: List<Pair<Long, Int>>,
    val coach: RunFile.CoachLog?,
) {
    /** Why a payload cannot be imported. Nothing has been written when this is thrown. */
    class Invalid(message: String) : Exception(message)

    companion object {
        const val VERSION = 1
        const val MAX_BYTES = 2_000_000
        const val MAX_RATE_S = 3600

        /** The last lap's end distance and the final sample's distance may differ by this much (both are the watch's). */
        const val END_DISTANCE_TOLERANCE_M = 5.0

        /** In a stretch with `rateS` 0 a sample must lie this close to every whole km (unit of `units`). */
        const val KM_SAMPLE_TOLERANCE_M = 25.0

        /** CRC-32/ISO-HDLC of [bytes] as an unsigned 32-bit value (see the class comment for the contract). */
        fun crc32(bytes: ByteArray): Long {
            var crc = -1
            for (b in bytes) {
                crc = crc xor (b.toInt() and 0xFF)
                repeat(8) { crc = if ((crc and 1) != 0) (crc ushr 1) xor 0xEDB88320.toInt() else crc ushr 1 }
            }
            return crc.inv().toLong() and 0xFFFFFFFFL
        }

        /** Parses and fully validates [text]; throws [Invalid] on anything the run file reader would refuse. */
        fun parse(text: String): WatchRunPayload {
            val root = try {
                Json.parse(text)
            } catch (e: Json.ParseException) {
                throw Invalid("not JSON: ${e.message}")
            }
            @Suppress("UNCHECKED_CAST")
            val m = root as? Map<String, Any?> ?: throw Invalid("top level must be an object")
            if (m["v"] != VERSION.toLong()) throw Invalid("unsupported payload version ${m["v"]}")

            val runId = str(m, "runId")
            if (!safeId(runId)) throw Invalid("unsafe runId")
            val model = str(m, "model")
            if (model.length > 64 || !model.all { it in 'a'..'z' || it in 'A'..'Z' || it in '0'..'9' || it == '-' || it == '_' || it == '.' }) {
                throw Invalid("bad model")
            }
            val mode = str(m, "mode")
            if (mode != "free") throw Invalid("mode '$mode' is not supported from the watch yet")
            val units = Units.entries.firstOrNull { it.name == str(m, "units") } ?: throw Invalid("units must be km|mi")
            val start = long(m, "startEpochMs")
            val end = long(m, "endEpochMs")
            if (start < 0 || end < start) throw Invalid("end before start")
            val elapsed = end - start

            val samples = ArrayList<RunFile.Sample>()
            for (raw in list(m, "samples")) {
                val r = raw as? List<*> ?: throw Invalid("sample must be a list")
                if (r.size != 8) throw Invalid("sample must have 8 fields")
                val t = int(r[0], "sample.t")
                val dist = num(r[6], "sample.distM")
                if (t < 0 || t > elapsed) throw Invalid("sample t outside the run")
                if (dist < 0.0) throw Invalid("negative distM")
                val last = samples.lastOrNull()
                if (last != null && t <= last.t) throw Invalid("samples must ascend in t")
                if (last != null && dist < last.distM) throw Invalid("distM must not decrease")
                val lat = numOrNull(r[1], "sample.lat")
                val lon = numOrNull(r[2], "sample.lon")
                if ((lat == null) != (lon == null)) throw Invalid("lat/lon must both be set or null")
                if (lat != null && (lat !in -90.0..90.0 || lon!! !in -180.0..180.0)) throw Invalid("lat/lon out of range")
                val hr = r[7]?.let { int(it, "sample.hr") }
                if (hr != null && hr <= 0) throw Invalid("hr must be > 0 or null")
                samples.add(RunFile.Sample(t, lat, lon, numOrNull(r[3], "sample.alt"), numOrNull(r[4], "sample.acc"), numOrNull(r[5], "sample.speed"), dist, hr?.toInt()))
            }

            val laps = ArrayList<RunFile.Lap>()
            for (raw in list(m, "laps")) {
                @Suppress("UNCHECKED_CAST")
                val l = raw as? Map<String, Any?> ?: throw Invalid("lap must be an object")
                val i = int(l["i"], "lap.i")
                val t0 = int(l["t0"], "lap.t0")
                val t1 = int(l["t1"], "lap.t1")
                val d0 = num(l["d0"], "lap.d0")
                val d1 = num(l["d1"], "lap.d1")
                val kind = LapKind.entries.firstOrNull { it.name == l["kind"] && it != LapKind.pause } ?: throw Invalid("lap.kind must be manual|auto")
                if (i != laps.size.toLong()) throw Invalid("laps must be indexed 0..n-1")
                if (t0 < 0 || t1 < t0 || t1 > elapsed) throw Invalid("lap ${laps.size} outside the run")
                if (d0 < 0.0 || d1 < d0) throw Invalid("lap ${laps.size} distance goes backwards")
                laps.lastOrNull()?.let { if (t0 < it.t1) throw Invalid("laps must not overlap") }
                laps.add(RunFile.Lap(i.toInt(), t0, t1, d0, d1, kind))
            }

            val pauses = spans(m, "pauses", elapsed, allowAuto = true)
            val gaps = spans(m, "gaps", elapsed, allowAuto = false)

            val rateChanges = ArrayList<Pair<Long, Int>>()
            val rawRates = list(m, "rateChanges")
            if (rawRates.isEmpty()) throw Invalid("rateChanges must not be empty")
            for (raw in rawRates) {
                val r = raw as? List<*> ?: throw Invalid("rate change must be [atMs, rateS]")
                if (r.size != 2) throw Invalid("rate change must be [atMs, rateS]")
                val at = int(r[0], "rateChanges.atMs")
                val rate = int(r[1], "rateChanges.rateS")
                if (at < 0 || rate < 0 || rate > MAX_RATE_S) throw Invalid("rate change out of range")
                if (rateChanges.isEmpty() && at != 0L) throw Invalid("rateChanges must start at 0")
                if (rateChanges.isNotEmpty() && at <= rateChanges.last().first) throw Invalid("rateChanges must ascend")
                rateChanges.add(at to rate.toInt())
            }

            // The laps and the samples are both the watch's figures and must tell one story.
            val lastLap = laps.lastOrNull()
            val lastSample = samples.lastOrNull()
            if (lastLap != null && lastSample != null && kotlin.math.abs(lastLap.d1 - lastSample.distM) > END_DISTANCE_TOLERANCE_M) {
                throw Invalid("last lap ends at ${lastLap.d1} m but the final sample is at ${lastSample.distM} m")
            }
            // No-track stretches: a whole-km split cannot be read off a track that is not there, so the watch
            // must send a distance-only sample at each whole km it crossed (the rest is interpolated otherwise).
            val unitM = if (units == Units.mi) 1609.344 else 1000.0
            val finalM = lastSample?.distM ?: 0.0
            var km = 1
            var idx = 0
            while (km * unitM <= finalM) {
                val target = km * unitM
                while (idx < samples.size && samples[idx].distM < target) idx++
                val after = samples[idx]
                val before = samples.getOrNull(idx - 1)
                val untracked = rateAt(rateChanges, after.t) == 0 || (before != null && rateAt(rateChanges, before.t) == 0)
                if (untracked && samples.none { kotlin.math.abs(it.distM - target) <= KM_SAMPLE_TOLERANCE_M }) {
                    throw Invalid("no distance sample within ${KM_SAMPLE_TOLERANCE_M.toInt()} m of whole km $km in a stretch with no track")
                }
                km++
            }

            return WatchRunPayload(
                runId, model, str(m, "appVersion"), start, end, str(m, "tz"), units,
                laps, pauses, gaps, samples, rateChanges, coach(m["coach"]),
            )
        }

        private fun rateAt(changes: List<Pair<Long, Int>>, t: Long): Int = changes.lastOrNull { it.first <= t }?.second ?: 0

        private fun coach(raw: Any?): RunFile.CoachLog? {
            if (raw == null) return null
            val c = raw as? Map<*, *> ?: throw Invalid("coach must be an object")
            if (c.keys.any { it != "choice" && it != "cues" && it != "prompts" }) throw Invalid("unknown coach key")
            val choice = c["choice"]
            if (choice != null && (choice !is String || choice.isEmpty())) throw Invalid("coach.choice must be a string")
            val cues = ((c["cues"] ?: emptyList<Any?>()) as? List<*> ?: throw Invalid("coach.cues must be a list")).map {
                val r = it as? List<*> ?: throw Invalid("coach cue must be [kind, km, tMs]")
                if (r.size != 3 || r[0] !is String) throw Invalid("coach cue must be [kind, km, tMs]")
                RunFile.CoachLog.Cue(r[0] as String, int(r[1], "cue.km").toInt(), int(r[2], "cue.tMs"))
            }
            val prompts = ((c["prompts"] ?: emptyList<Any?>()) as? List<*> ?: throw Invalid("coach.prompts must be a list")).map {
                val r = it as? List<*> ?: throw Invalid("coach prompt must be a 7-element list")
                if (r.size != 7 || r[0] !is String || r[2] !is String || r[3] !is String) throw Invalid("coach prompt shape")
                val options = (r[1] as? List<*> ?: throw Invalid("coach prompt options")).map { o -> o as? String ?: throw Invalid("coach prompt options") }
                RunFile.CoachLog.Prompt(r[0] as String, options, r[2] as String, r[3] as String, int(r[4], "prompt.km").toInt(), int(r[5], "prompt.openedMs"), int(r[6], "prompt.answeredMs"))
            }
            if (choice == null && cues.isEmpty() && prompts.isEmpty()) return null
            return RunFile.CoachLog(choice as String?, cues, prompts)
        }

        private fun spans(m: Map<String, Any?>, key: String, elapsed: Long, allowAuto: Boolean): List<LongArray> {
            val out = ArrayList<LongArray>()
            for (raw in list(m, key)) {
                val r = raw as? List<*> ?: throw Invalid("$key entry must be a list")
                val auto = r.size == 3 && allowAuto && r[2] == RunFile.AUTO_PAUSE_KIND
                if (!(r.size == 2 || auto)) throw Invalid("$key entry must be [t0, t1]" + if (allowAuto) " or [t0, t1, \"auto\"]" else "")
                val t0 = int(r[0], "$key.t0")
                val t1 = int(r[1], "$key.t1")
                if (t0 < 0 || t1 < t0 || t1 > elapsed) throw Invalid("$key entry outside the run")
                if (out.isNotEmpty() && t0 < out.last()[1]) throw Invalid("$key entries must ascend")
                out.add(if (auto) longArrayOf(t0, t1, 1) else longArrayOf(t0, t1))
            }
            return out
        }

        /** The run id becomes a file name the Dart reader also accepts: ASCII letters, digits and `-`, at most 64. */
        private fun safeId(id: String) =
            id.isNotEmpty() && id.length <= 64 && id[0] != '-' && id.all { it in 'a'..'z' || it in 'A'..'Z' || it in '0'..'9' || it == '-' }

        private fun str(m: Map<String, Any?>, k: String): String =
            (m[k] as? String)?.takeIf { it.isNotEmpty() } ?: throw Invalid("$k must be a non-empty string")

        private fun long(m: Map<String, Any?>, k: String): Long = int(m[k], k)

        private fun list(m: Map<String, Any?>, k: String): List<*> = when (val v = m[k]) {
            null -> emptyList<Any?>()
            is List<*> -> v
            else -> throw Invalid("$k must be a list")
        }

        /** Whole numbers only: the run file reader refuses a float where it wants an int. */
        private fun int(v: Any?, what: String): Long = v as? Long ?: throw Invalid("$what must be an integer")

        private fun num(v: Any?, what: String): Double = (v as? Number)?.toDouble() ?: throw Invalid("$what must be a number")

        private fun numOrNull(v: Any?, what: String): Double? = if (v == null) null else num(v, what)
    }
}
