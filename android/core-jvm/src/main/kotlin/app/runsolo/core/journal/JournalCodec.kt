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
import app.runsolo.core.model.Preset
import app.runsolo.core.model.RunMode
import app.runsolo.core.model.Units

/** Line ↔ JSON. Keys are short because the journal is written at 1 Hz for an hour. */
object JournalCodec {
    const val SCHEMA = 1

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
                m["preset"] = line.preset?.toJson()
                m["units"] = line.units.name
            }
            is JournalLine.Sample -> {
                m["k"] = "s"
                m["t"] = line.t
                m["w"] = line.w
                m["lat"] = line.lat
                m["lon"] = line.lon
                if (line.altM != null) m["alt"] = line.altM
                m["acc"] = line.accuracyM
                if (line.speedMps != null) m["spd"] = line.speedMps
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

    /** Throws [Json.ParseException] or [IllegalArgumentException] on a malformed line. */
    fun decode(text: String): JournalLine {
        val m = Json.parseObject(text)
        val t = m.long("t")
        val w = m.longOrNull("w") ?: 0L
        return when (val k = m.string("k")) {
            "hdr" -> JournalLine.Header(
                t = t,
                w = w,
                id = m.string("id"),
                device = m.string("device"),
                app = m.string("app"),
                tz = m.string("tz"),
                mode = RunMode.valueOf(m.string("mode")),
                preset = Preset.fromJson(m.obj("preset")),
                units = Units.valueOf(m.string("units")),
            )
            "s" -> JournalLine.Sample(
                t = t,
                w = w,
                lat = m.double("lat"),
                lon = m.double("lon"),
                altM = m.doubleOrNull("alt"),
                accuracyM = m.double("acc"),
                speedMps = m.doubleOrNull("spd"),
                hr = m.longOrNull("hr")?.toInt(),
            )
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
