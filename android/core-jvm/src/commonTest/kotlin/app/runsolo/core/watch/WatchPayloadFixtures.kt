package app.runsolo.core.watch

import app.runsolo.core.fs.FakeFileSystem
import app.runsolo.core.json.Json
import app.runsolo.core.platform.cos
import app.runsolo.core.platform.encodeUtf8
import app.runsolo.core.platform.sin
import app.runsolo.core.run.RunFile
import app.runsolo.core.run.RunPaths
import kotlin.math.PI
import kotlin.math.roundToLong

/**
 * Watch payloads as the watch would send them (body maps), and the run files the importer turns them into.
 * Deterministic and hand-specified: the watch's `distM` is the arc length the runner covered, and the laps are
 * the watch's own km splits, so the importer's job is to carry them unchanged.
 */
object WatchPayloadFixtures {
    private const val W0 = 1_758_672_000_000L // 2025-09-24T00:00:00Z, as every contract fixture
    private const val LAT0 = -33.8688
    private const val LON0 = 151.2093
    private const val SPEED = 3.0 // m/s

    private fun r(v: Double, dp: Int): Double {
        var p = 1.0
        repeat(dp) { p *= 10.0 }
        return (v * p).roundToLong() / p
    }

    /** A fix [metres] along a circle of [radiusM], rounded as a run file stores it. */
    fun fix(metres: Double, radiusM: Double = 250.0): List<Double> {
        val theta = metres / radiusM
        val dLat = radiusM * (1 - cos(theta)) / 111_320.0
        val dLon = radiusM * sin(theta) / (111_320.0 * cos(LAT0 * PI / 180))
        return listOf(r(LAT0 + dLat, 6), r(LON0 + dLon, 6))
    }

    private fun trackSample(tMs: Long, hr: Int?): List<Any?> {
        val d = r(SPEED * tMs / 1000.0, 1)
        val f = fix(d)
        return listOf(tMs, f[0], f[1], 20.0, 4.0, SPEED, d, hr)
    }

    /** A no-fix sample: the watch's distance at an instant it did not sample the track (lap boundaries, the close). */
    private fun distOnly(tMs: Long, hr: Int?): List<Any?> = listOf(tMs, null, null, null, null, null, r(SPEED * tMs / 1000.0, 1), hr)

    private fun lap(i: Int, t0: Long, t1: Long, kind: String) =
        linkedMapOf<String, Any?>("i" to i, "t0" to t0, "t1" to t1, "d0" to r(SPEED * t0 / 1000.0, 1), "d1" to r(SPEED * t1 / 1000.0, 1), "kind" to kind)

    private fun body(
        runId: String,
        endMs: Long,
        laps: List<Map<String, Any?>>,
        samples: List<List<Any?>>,
        rateChanges: List<List<Long>>,
        pauses: List<List<Any?>> = emptyList(),
        coach: Map<String, Any?>? = null,
    ): LinkedHashMap<String, Any?> = linkedMapOf<String, Any?>(
        "v" to WatchRunPayload.VERSION,
        "runId" to runId,
        "model" to "forerunner265",
        "appVersion" to "0.1.0",
        "startEpochMs" to W0,
        "endEpochMs" to W0 + endMs,
        "tz" to "Australia/Sydney",
        "units" to "km",
        "mode" to "free",
        "laps" to laps,
        "pauses" to pauses,
        "gaps" to emptyList<Any?>(),
        "samples" to samples,
        "rateChanges" to rateChanges,
    ).also { if (coach != null) it["coach"] = coach }

    /** 10 min at 3 m/s with a 5 s track: one km split logged at 333 s (the watch's own, 999 m by its clock), the rest a manual lap. */
    fun fiveSecondTrack(): LinkedHashMap<String, Any?> {
        val end = 600_000L
        val split = 333_000L // 999 m; the watch's own split is 1 km at 333.3 s, rounded to the second it logs
        return body(
            "gw-5strack", end,
            laps = listOf(lap(0, 0, split, "auto"), lap(1, split, end, "manual")),
            samples = (0..end step 5_000).map { trackSample(it, 140 + (it / 5_000).toInt() % 9) },
            rateChanges = listOf(listOf(0L, 5L)),
        )
    }

    /** The watch ran out of room: 5 s samples, then no track from 6 min. Distance and laps keep coming, as no-fix samples. */
    fun thinned(): LinkedHashMap<String, Any?> {
        val end = 600_000L
        val split = 333_000L
        val cutoff = 360_000L
        val samples = (0..cutoff step 5_000).map { trackSample(it, 150) } + listOf(distOnly(end, 155))
        return body(
            "gw-thinned", end,
            laps = listOf(lap(0, 0, split, "auto"), lap(1, split, end, "manual")),
            samples = samples,
            rateChanges = listOf(listOf(0L, 5L), listOf(cutoff, 0L)),
            coach = linkedMapOf(
                "choice" to "chase",
                "cues" to listOf(listOf("ahead", 1, 333_000)),
                "prompts" to listOf(listOf("slipping", listOf("push", "hold"), "hold", "button", 1, 340_000, 344_000)),
            ),
        )
    }

    /** Two degrade steps: 5 s samples, 10 s samples from 4 min, none from 7 min. Three entries, so the Dart reader sees more than one change. */
    fun twoStepDegrade(): LinkedHashMap<String, Any?> {
        val end = 600_000L
        val split = 333_000L
        val samples = (0..240_000L step 5_000).map { trackSample(it, 146) } +
            (250_000L..420_000L step 10_000).map { trackSample(it, 149) } +
            listOf(distOnly(end, 153))
        return body(
            "gw-degrade2", end,
            laps = listOf(lap(0, 0, split, "auto"), lap(1, split, end, "manual")),
            samples = samples,
            rateChanges = listOf(listOf(0L, 5L), listOf(240_000L, 10L), listOf(420_000L, 0L)),
        )
    }

    /** No track at all: a sample at the start, at the split and at the close, laps and distance from the watch. */
    fun splitsOnly(): LinkedHashMap<String, Any?> {
        val end = 600_000L
        val split = 333_000L
        return body(
            "gw-splitsonly", end,
            laps = listOf(lap(0, 0, split, "auto"), lap(1, split, end, "manual")),
            samples = listOf(distOnly(0, null), distOnly(split, 148), distOnly(end, 151)),
            rateChanges = listOf(listOf(0L, 0L)),
        )
    }

    /** What the importer writes for [body], decoded to the run file's JSON as the contract fixtures hold it. */
    fun importedJson(body: Map<String, Any?>): String {
        val fs = FakeFileSystem()
        val result = WatchRunImporter(fs).import(encodeUtf8(WatchRunPayload.sign(body)))
        check(result is WatchRunImporter.Result.Imported) { "fixture payload rejected: $result" }
        return Json.write(RunFile.readJson(fs.readBytes(RunPaths.runFile(body["runId"] as String))))
    }
}
