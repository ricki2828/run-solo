package app.runsolo.core.contract

import app.runsolo.core.fs.FakeFileSystem
import app.runsolo.core.journal.JournalLine
import app.runsolo.core.journal.JournalWriter
import app.runsolo.core.json.Json
import app.runsolo.core.model.HrReading
import app.runsolo.core.model.LapSource
import app.runsolo.core.model.LocationFix
import app.runsolo.core.model.Phase
import app.runsolo.core.model.Preset
import app.runsolo.core.model.RunMode
import app.runsolo.core.model.Units
import app.runsolo.core.record.RecorderCore
import app.runsolo.core.record.SampleTicker
import app.runsolo.core.replay.TraceFixture
import app.runsolo.core.run.Finaliser
import app.runsolo.core.run.RunFile
import app.runsolo.core.run.RunPaths
import java.io.File

/**
 * Kotlin→Dart contract fixtures: the real pipeline end to end — `SampleTicker` (1 Hz rule,
 * no-fix ticks, HR join) + `RecorderCore` (laps, cues, phases) → `JournalWriter` on a
 * `FakeFileSystem` → `Finaliser` → the gzip'd run file, decoded back to JSON. Nothing is
 * hand-built. Checked into `src/test/fixtures/contract/schema2/` and copied verbatim into
 * `packages/run_engine/test/fixtures/contract/schema2/`; [ContractFixturesTest] fails when the
 * generator and the checked-in files drift, and CI compares the two copies. The four schema-1
 * files under `contract/schema1/` are frozen output of the Phase-1 writer (plan §18.7): never
 * regenerated, they pin the v1 `free` → `laps` mapping on the Dart side.
 *
 * Regenerate: `java -cp <test classpath> app.runsolo.core.contract.ContractFixturesKt`.
 */
object ContractFixtures {
    const val DIR = "src/test/fixtures/contract/schema2"
    const val SCHEMA1_DIR = "src/test/fixtures/contract/schema1"
    private const val T0 = 1_000_000L
    private const val W0 = 1_758_672_000_000L // 2025-09-24T00:00:00Z
    private const val LAT0 = -33.8688
    private const val LON0 = 151.2093

    fun all(): Map<String, String> = linkedMapOf(
        "four_by_four_preset_auto_hr" to fourByFourPresetAutoHr(),
        "treadmill_no_fix_hr" to treadmillNoFixHr(),
        "gps_dropout_hr" to gpsDropoutHr(),
        "laps_run_pause_manual_laps" to lapsRunPauseManualLaps(),
        "free_run_no_laps" to freeRunNoLaps(),
    )

    /** One simulated recording: a service loop over the core, per second. */
    private class Session(id: String, mode: RunMode, preset: Preset?) {
        val fs = FakeFileSystem()
        val writer = JournalWriter(fs, id, onWriteFailed = { throw it })
        val ticker = SampleTicker(wall = { wall })
        val core = RecorderCore(mode, preset)
        private val id = id
        var t = T0
        var wall = W0

        init {
            fs.mkdirs(RunPaths.RUNS_DIR)
            writer.open()
            writer.append(JournalLine.Header(T0, W0, id, "contract-fixture", "core-jvm-test", "Australia/Sydney", mode, preset, Units.km))
            emit(core.start(T0))
        }

        fun emit(out: List<RecorderCore.Output>) {
            for (o in out) {
                when (o) {
                    is RecorderCore.Output.Lap -> writer.append(JournalLine.Lap(o.t, wall, o.source))
                    is RecorderCore.Output.Cue -> writer.append(JournalLine.Cue(o.t, wall, o.kind))
                    is RecorderCore.Output.PhaseChanged -> Unit
                }
            }
        }

        /** Advance one second: deliver [fix] (if any) and [hr] (if any), tick core + sampler, journal. */
        fun second(fix: LocationFix?, hr: Int?, before: () -> Unit = {}) {
            t += 1000
            wall += 1000
            hr?.let { ticker.onHr(HrReading(t - 200, it)) }
            fix?.let { ticker.onFix(it.copy(t = t)) }
            before()
            emit(core.tick(t))
            for (s in ticker.tick(t)) writer.append(s)
        }

        fun lap(source: LapSource) = emit(core.lap(source, t).second)
        fun pause() { core.pause(t); writer.append(JournalLine.Pause(t, wall)) }
        fun resume() { core.resume(t); writer.append(JournalLine.Resume(t, wall)) }

        fun finish(): String {
            emit(core.stop(t))
            writer.close()
            val done = Finaliser(fs).finalise(id, wall, activeRunId = null) as Finaliser.Outcome.Done
            return Json.write(RunFile.readJson(fs.readBytes(done.path)))
        }
    }

    /** 60 s warmup, notification LAP, 4×(4:00 @4.2 m/s, 3:00 @2.0 m/s) auto-lapped by the core, 60 s cooldown; HR by phase. */
    private fun fourByFourPresetAutoHr(): String {
        val preset = Preset.DEFAULT_4X4
        val segments = ArrayList<Pair<Int, Double>>()
        segments.add(60 to 2.5)
        repeat(preset.reps) { segments.add(preset.workSeconds to 4.2); segments.add(preset.recoverySeconds to 2.0) }
        segments.add(60 to 2.5)
        val fixes = TraceFixture.straightLine(segments, LAT0, LON0, 6.0, T0)
        val s = Session("contract-4x4-preset", RunMode.fourByFour, preset)
        for ((i, f) in fixes.withIndex()) {
            if (i == 0) continue // the generator's t=0 point is the start position; recording begins at second 1
            val hr = when (s.core.phase) {
                Phase.work -> 165 + (i % 5)
                Phase.recovery -> 145
                else -> 130
            }
            s.second(f, hr) { if (i == 60) s.lap(LapSource.notification) }
        }
        return s.finish()
    }

    /** 10 min Laps run with no GPS fix at all, HR ramp 120→150, one manual lap at 5:00. */
    private fun treadmillNoFixHr(): String {
        val s = Session("contract-treadmill", RunMode.laps, null)
        for (i in 1..600) s.second(null, 120 + (30 * i) / 600) { if (i == 300) s.lap(LapSource.button) }
        return s.finish()
    }

    /** 6 min Free run at 3 m/s; fixes lost from 2:00 to 2:45 (no-fix ticks carry HR 150); the runner keeps moving. */
    private fun gpsDropoutHr(): String {
        val fixes = TraceFixture.straightLine(listOf(360 to 3.0), LAT0, LON0, 7.0, T0)
        val s = Session("contract-gps-dropout", RunMode.free, null)
        for ((i, f) in fixes.withIndex()) {
            if (i == 0) continue
            s.second(if (i in 120..165) null else f, 150)
        }
        return s.finish()
    }

    /** Laps run, manual laps at 3:00 and 6:00, a 20 s standing pause at 4:30 (fixes keep coming, no HR strap). */
    private fun lapsRunPauseManualLaps(): String {
        val fixes = TraceFixture.straightLine(listOf(270 to 3.0, 20 to 0.0, 250 to 3.0), LAT0, LON0, 5.0, T0)
        val s = Session("contract-pause", RunMode.laps, null)
        for ((i, f) in fixes.withIndex()) {
            if (i == 0) continue
            s.second(f, null) {
                if (i == 180 || i == 360) s.lap(LapSource.button)
                if (i == 270) s.pause()
                if (i == 290) s.resume()
            }
        }
        return s.finish()
    }

    /**
     * Schema-2 Free run (plan §18.2): 8 min at 3 m/s with HR, a 15 s pause at 4:00, and LAP presses
     * from every source at 2:00, 5:00 and 6:00 that the core must ignore — the file has exactly one
     * lap segment `[0, end]`.
     */
    private fun freeRunNoLaps(): String {
        val fixes = TraceFixture.straightLine(listOf(240 to 3.0, 15 to 0.0, 225 to 3.0), LAT0, LON0, 5.0, T0)
        val s = Session("contract-free", RunMode.free, null)
        for ((i, f) in fixes.withIndex()) {
            if (i == 0) continue
            s.second(f, 140 + (i % 7)) {
                if (i == 120) s.lap(LapSource.button)
                if (i == 240) s.pause()
                if (i == 255) s.resume()
                if (i == 300) s.lap(LapSource.notification)
                if (i == 360) s.lap(LapSource.volumeKey)
            }
        }
        return s.finish()
    }

    fun write(dir: File = File(DIR)) {
        dir.mkdirs()
        for ((name, json) in all()) File(dir, "$name.json").writeText(json + "\n")
    }
}

fun main() {
    ContractFixtures.write()
    println("wrote ${ContractFixtures.all().size} fixtures to ${ContractFixtures.DIR}")
}
