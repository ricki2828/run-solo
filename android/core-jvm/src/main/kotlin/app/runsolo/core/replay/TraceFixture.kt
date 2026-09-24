package app.runsolo.core.replay

import app.runsolo.core.json.Json
import app.runsolo.core.json.list
import app.runsolo.core.model.HrReading
import app.runsolo.core.model.LocationFix
import kotlin.math.cos

/**
 * Fixture loaders for replay mode. Two shapes:
 *  - CSV `t_ms,lat,lon,alt,acc,speed[,hr]` (blank alt/speed/hr → null; `#` comments allowed)
 *  - a schema v1 run file's JSON (`samples: [[t, lat, lon, alt, acc, speed, dist, hr], …]`),
 *    so any exported run replays as a fixture; `dist` is ignored (recomputed live) and a
 *    no-fix sample (`lat`/`lon` null) contributes only its HR.
 */
object TraceFixture {
    data class Trace(val fixes: List<LocationFix>, val hr: List<HrReading>)

    fun fromCsv(text: String): Trace {
        val fixes = ArrayList<LocationFix>()
        val hr = ArrayList<HrReading>()
        for (raw in text.lineSequence()) {
            val line = raw.substringBefore('#').trim()
            if (line.isEmpty()) continue
            val c = line.split(',').map { it.trim() }
            require(c.size >= 6) { "trace row needs ≥ 6 columns: $line" }
            val t = c[0].toLong()
            fixes.add(
                LocationFix(
                    t = t,
                    lat = c[1].toDouble(),
                    lon = c[2].toDouble(),
                    altM = c[3].toDoubleOrNull(),
                    accuracyM = c[4].toDouble(),
                    speedMps = c[5].toDoubleOrNull(),
                ),
            )
            if (c.size >= 7) c[6].toIntOrNull()?.let { hr.add(HrReading(t, it)) }
        }
        return Trace(fixes, hr)
    }

    fun fromRunFileJson(text: String): Trace {
        val m = Json.parseObject(text)
        val fixes = ArrayList<LocationFix>()
        val hr = ArrayList<HrReading>()
        for (row in m.list("samples")) {
            val s = row as List<*>
            val t = (s[0] as Number).toLong()
            val lat = s[1] as Number?
            val lon = s[2] as Number?
            val acc = s[4] as Number?
            if (lat != null && lon != null && acc != null) {
                fixes.add(
                    LocationFix(
                        t = t,
                        lat = lat.toDouble(),
                        lon = lon.toDouble(),
                        altM = (s[3] as Number?)?.toDouble(),
                        accuracyM = acc.toDouble(),
                        speedMps = (s[5] as Number?)?.toDouble(),
                    ),
                )
            }
            (s.getOrNull(7) as Number?)?.let { hr.add(HrReading(t, it.toInt())) }
        }
        return Trace(fixes, hr)
    }

    /**
     * Synthetic straight-line trace at 1 Hz: [segments] of (seconds, m/s) heading east from
     * [lat0]/[lon0]. Ground truth by construction, for core tests and the desk 4x4.
     */
    fun straightLine(
        segments: List<Pair<Int, Double>>,
        lat0: Double = -33.8688,
        lon0: Double = 151.2093,
        accuracyM: Double = 8.0,
        startT: Long = 0,
    ): List<LocationFix> {
        val out = ArrayList<LocationFix>()
        var t = startT
        var eastM = 0.0
        val mPerDegLon = 111_320.0 * cos(Math.toRadians(lat0))
        out.add(LocationFix(t, lat0, lon0, 10.0, accuracyM, 0.0))
        for ((seconds, mps) in segments) {
            repeat(seconds) {
                t += 1000
                eastM += mps
                out.add(LocationFix(t, lat0, lon0 + eastM / mPerDegLon, 10.0, accuracyM, mps))
            }
        }
        return out
    }
}
