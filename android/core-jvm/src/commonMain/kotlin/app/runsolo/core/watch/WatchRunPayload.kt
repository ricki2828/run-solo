package app.runsolo.core.watch

import app.runsolo.core.json.Json
import app.runsolo.core.model.LapKind
import app.runsolo.core.model.Units
import app.runsolo.core.run.RunFile

/**
 * A finished run as the Garmin watch sends it, reassembled from chunks by the transport layer (G4/G5) and
 * handed to [WatchRunImporter]. Pure data plus [parse]; nothing here touches storage.
 *
 * Wire form (UTF-8 JSON object, [VERSION] 1). Rows reuse the run file's shapes so the importer maps them 1:1:
 * ```
 * { "v": 1, "payloadHash": "<8 hex>", "runId": "gw-<hex>", "model": "forerunner265", "appVersion": "0.1.0",
 *   "startEpochMs": .., "endEpochMs": .., "tz": "..", "units": "km", "mode": "free",
 *   "laps":   [{"i":0,"t0":..,"t1":..,"d0":..,"d1":..,"kind":"manual"}],
 *   "pauses": [[t0,t1] | [t0,t1,"auto"]],  "gaps": [[t0,t1]],
 *   "samples": [[t,lat?,lon?,altM?,accuracyM?,speedMps?,distM,hr?]],   // distM = the watch's elapsedDistance
 *   "rateChanges": [[atMs, rateS], ..],
 *   "coach": {"choice"?: "..", "cues": [[kind,km,tMs]], "prompts"?: [[trigger,[options],choice,source,km,openedMs,answeredMs]]} }
 * ```
 * `payloadHash` is [hashOf] the body: CRC-32 (IEEE), 8 lowercase hex digits, over the UTF-8 of
 * `Json.write(body without payloadHash)` where body is the parsed map (key order and number formatting as
 * `Json` writes them). A sender that is not Kotlin must therefore produce that canonical text, or send a hash
 * computed by the transport over exactly the bytes it carries (open point for G4).
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

        /** CRC-32 (IEEE 802.3) of [bytes], 8 lowercase hex digits. */
        fun crc32Hex(bytes: ByteArray): String {
            var crc = -1
            for (b in bytes) {
                crc = crc xor (b.toInt() and 0xFF)
                repeat(8) { crc = if ((crc and 1) != 0) (crc ushr 1) xor 0xEDB88320.toInt() else crc ushr 1 }
            }
            return (crc.inv().toLong() and 0xFFFFFFFFL).toString(16).padStart(8, '0')
        }

        /** The canonical hash of a payload body (the parsed map, with or without its `payloadHash`). */
        fun hashOf(body: Map<String, Any?>): String {
            val canonical = LinkedHashMap(body)
            canonical.remove("payloadHash")
            return crc32Hex(app.runsolo.core.platform.encodeUtf8(Json.write(canonical)))
        }

        /** Body + its `payloadHash`, as the wire text. Used by tests and by any Kotlin sender. */
        fun sign(body: Map<String, Any?>): String {
            val out = LinkedHashMap(body)
            out.remove("payloadHash")
            out["payloadHash"] = hashOf(body)
            return Json.write(out)
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
            val hash = m["payloadHash"] as? String ?: throw Invalid("payloadHash missing")
            if (hash != hashOf(m)) throw Invalid("payload hash mismatch")

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

            return WatchRunPayload(
                runId, model, str(m, "appVersion"), start, end, str(m, "tz"), units,
                laps, pauses, gaps, samples, rateChanges, coach(m["coach"]),
            )
        }

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
