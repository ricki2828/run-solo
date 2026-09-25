package app.runsolo.core.journal

import app.runsolo.core.json.Json
import app.runsolo.core.json.double
import app.runsolo.core.json.doubleOrNull
import app.runsolo.core.json.long
import app.runsolo.core.json.longOrNull
import app.runsolo.core.json.obj
import app.runsolo.core.json.string
import app.runsolo.core.model.CueKind
import app.runsolo.core.model.LapSource
import app.runsolo.core.model.RunMode
import app.runsolo.core.model.SessionSpec
import app.runsolo.core.model.Units

/** Line ↔ JSON. Keys are short because the journal is written at 1 Hz for an hour. */
object JournalCodec {
    /**
     * Bumps with the run-file schema (plan §18.7): 2 = `mode` gained laps/free-without-laps/cooper;
     * 3 = `fourByFour` → `intervals`, header `preset` → `session` (Phase 3 §3.8).
     */
    const val SCHEMA = 3

    /** The header was written by a newer app (schema above [SCHEMA] or a mode this build does not know). */
    class NewerSchema(message: String) : IllegalArgumentException(message)

    /** Non-finite doubles are not JSON; a NaN altitude/speed from the platform becomes "absent". */
    private fun Double?.finiteOrNull(): Double? = this?.takeIf { it.isFinite() }

    fun encode(line: JournalLine): String {
        val m = LinkedHashMap<String, Any?>()
        when (line) {
            is JournalLine.Header -> {
                m["k"] = "hdr"
                m["schema"] = SCHEMA
                m["t"] = line.t
                m["w"] = line.w
                m["id"] = line.id
                m["device"] = line.device
                m["app"] = line.app
                m["tz"] = line.tz
                m["mode"] = line.mode.name
                m["session"] = line.session?.toJson()
                m["units"] = line.units.name
            }
            is JournalLine.Sample -> {
                m["k"] = "s"
                m["t"] = line.t
                m["w"] = line.w
                // A fix is all-or-nothing; a non-finite coordinate/accuracy demotes the tick to no-fix.
                val lat = line.lat.finiteOrNull()
                val lon = line.lon.finiteOrNull()
                val acc = line.accuracyM.finiteOrNull()
                if (lat != null && lon != null && acc != null) {
                    m["lat"] = lat
                    m["lon"] = lon
                    line.altM.finiteOrNull()?.let { m["alt"] = it }
                    m["acc"] = acc
                    line.speedMps.finiteOrNull()?.let { m["spd"] = it }
                }
                if (line.hr != null) m["hr"] = line.hr
            }
            is JournalLine.Lap -> { m["k"] = "lap"; m["t"] = line.t; m["w"] = line.w; m["src"] = line.source.name }
            is JournalLine.Pause -> { m["k"] = "pause"; m["t"] = line.t; m["w"] = line.w }
            is JournalLine.Resume -> { m["k"] = "resume"; m["t"] = line.t; m["w"] = line.w }
            is JournalLine.Cue -> { m["k"] = "cue"; m["t"] = line.t; m["w"] = line.w; m["kind"] = line.kind.name }
            is JournalLine.Gap -> { m["k"] = "gap"; m["t"] = line.t; m["w"] = line.w; m["wall"] = line.wallGapMs }
            is JournalLine.HrLink -> { m["k"] = "hr"; m["t"] = line.t; m["w"] = line.w; m["on"] = line.connected }
        }
        return Json.write(m)
    }

    /**
     * Schema ≤ 2 `fourByFour` is `intervals` (Phase 3 §3.8). Schema-1 `free` was the
     * lap-capable by-feel run (volume laps on, manual laps journaled), so
     * it is `laps` now — always, not only when laps exist (plan §18.7 B1). Applied here, not in
     * `RecorderCore.restore`, because `RunMode.valueOf` runs first. An unknown mode name comes
     * from a newer app and is reported as such, never guessed.
     */
    fun decodeMode(name: String, schema: Long): RunMode {
        if (schema <= 1 && name == "free") return RunMode.laps
        if (schema <= 2 && name == RunMode.LEGACY_FOUR_BY_FOUR) return RunMode.intervals
        return RunMode.values().firstOrNull { it.name == name } ?: throw NewerSchema("unknown run mode '$name'")
    }

    /**
     * The header's session: schema 3 reads `session`; schema ≤ 2 maps `fourByFour` + `preset`
     * to the norwegian-4x4 spec (no preset = the standard 4 × 240/180) and `cooper` to the
     * Cooper spec, exactly as the Dart reader does for run files.
     */
    fun decodeSession(m: Map<String, Any?>, mode: RunMode, schema: Long): SessionSpec? {
        if (schema >= 3) return SessionSpec.fromJson(m.obj("session"))
        return when (mode) {
            RunMode.intervals -> SessionSpec.fromLegacyPreset(m.obj("preset"))
            RunMode.cooper -> SessionSpec.COOPER
            RunMode.laps, RunMode.free -> null
        }
    }

    /** Throws [Json.ParseException] or [IllegalArgumentException] on a malformed line; [NewerSchema] for a header from a newer app. */
    fun decode(text: String): JournalLine {
        val m = Json.parseObject(text)
        val t = m.long("t")
        val w = m.longOrNull("w") ?: 0L
        return when (val k = m.string("k")) {
            "hdr" -> {
                val schema = m.long("schema")
                if (schema > SCHEMA) throw NewerSchema("journal schema $schema is newer than $SCHEMA")
                val mode = decodeMode(m.string("mode"), schema)
                JournalLine.Header(
                    t = t,
                    w = w,
                    id = m.string("id"),
                    device = m.string("device"),
                    app = m.string("app"),
                    tz = m.string("tz"),
                    mode = mode,
                    session = decodeSession(m, mode, schema),
                    units = Units.valueOf(m.string("units")),
                )
            }
            "s" -> {
                // A fix is all-or-nothing: lat, lon and acc together, each numeric; otherwise no fix.
                val fixKeys = listOf("lat", "lon", "acc").filter { m.containsKey(it) }
                require(fixKeys.isEmpty() || fixKeys.size == 3) { "partial fix in sample line" }
                for (k in fixKeys) require(m[k] is Number) { "non-numeric '$k' in sample line" }
                JournalLine.Sample(
                    t = t,
                    w = w,
                    lat = m.doubleOrNull("lat"),
                    lon = m.doubleOrNull("lon"),
                    altM = m.doubleOrNull("alt"),
                    accuracyM = m.doubleOrNull("acc"),
                    speedMps = m.doubleOrNull("spd"),
                    hr = m.longOrNull("hr")?.toInt(),
                )
            }
            "lap" -> JournalLine.Lap(t, w, LapSource.valueOf(m.string("src")))
            "pause" -> JournalLine.Pause(t, w)
            "resume" -> JournalLine.Resume(t, w)
            "cue" -> JournalLine.Cue(t, w, CueKind.valueOf(m.string("kind")))
            "gap" -> JournalLine.Gap(t, w, m.long("wall"))
            "hr" -> JournalLine.HrLink(t, w, m["on"] as? Boolean ?: throw IllegalArgumentException("hr.on"))
            else -> throw IllegalArgumentException("Unknown journal line kind '$k'")
        }
    }
}
