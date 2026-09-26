package app.runsolo.core.contract

import app.runsolo.core.fs.FakeFileSystem
import app.runsolo.core.journal.JournalLine
import app.runsolo.core.journal.JournalWriter
import app.runsolo.core.json.Json
import app.runsolo.core.model.CueProfile
import app.runsolo.core.model.HrReading
import app.runsolo.core.model.LapSource
import app.runsolo.core.model.LocationFix
import app.runsolo.core.model.Phase
import app.runsolo.core.model.RecoveryStyle
import app.runsolo.core.model.RunMode
import app.runsolo.core.model.SessionSpec
import app.runsolo.core.model.Step
import app.runsolo.core.model.StepKind
import app.runsolo.core.model.TargetKind
import app.runsolo.core.model.Units
import app.runsolo.core.record.RecorderCore
import app.runsolo.core.record.SampleTicker
import app.runsolo.core.replay.ReplayScenarios
import app.runsolo.core.replay.TraceFixture
import app.runsolo.core.run.Finaliser
import app.runsolo.core.run.RunFile
import app.runsolo.core.run.RunPaths
import java.io.File

/**
 * Kotlin→Dart contract fixtures: the real pipeline end to end — `SampleTicker` (1 Hz rule,
 * no-fix ticks, HR join) + `RecorderCore` (laps, cues, phases) → `JournalWriter` on a
 * `FakeFileSystem` → `Finaliser` → the gzip'd run file, decoded back to JSON. Nothing is
 * hand-built. Checked into `src/test/fixtures/contract/` and copied verbatim into
 * `packages/run_engine/test/fixtures/contract/`; [ContractFixturesTest] fails when the
 * generator and the checked-in files drift, and CI compares the two copies. The top level is
 * schema 3 (Phase 3 §3.8). `contract/schema1/` and `contract/schema2/` are frozen output of the
 * older writers: never regenerated, they pin the v1 `free` → `laps` and the v2 `fourByFour` +
 * `preset` → `intervals` + norwegian-4x4 mappings on the Dart side.
 *
 * Regenerate: `java -cp <test classpath> app.runsolo.core.contract.ContractFixturesKt`.
 */
object ContractFixtures {
    const val DIR = "src/test/fixtures/contract"
    const val SCHEMA1_DIR = "src/test/fixtures/contract/schema1"
    const val SCHEMA2_DIR = "src/test/fixtures/contract/schema2"
    private const val T0 = 1_000_000L
    private const val W0 = 1_758_672_000_000L // 2025-09-24T00:00:00Z
    private const val LAT0 = -33.8688
    private const val LON0 = 151.2093

    fun all(): Map<String, String> = linkedMapOf(
        "four_by_four_preset_auto_hr" to fourByFourPresetAutoHr(),
        "four_by_four_3_reps" to fourByFourThreeReps(),
        "cooper_12min" to cooper12Min(),
        "fartlek_laps" to fartlekLaps(),
        "session_8x400_shape" to eightBy400Shape(),
        "parkrun_5k_autostop" to parkrun5kAutoStop(),
        "thirty_thirty_short" to thirtyThirtyShort(),
        "treadmill_no_fix_hr" to treadmillNoFixHr(),
        "gps_dropout_hr" to gpsDropoutHr(),
        "laps_run_pause_manual_laps" to lapsRunPauseManualLaps(),
        "free_run_no_laps" to freeRunNoLaps(),
    ) + ReplayScenarios.KINDS.associate { "replay_${it.replace('-', '_')}" to replayKind(it) }

    /** One simulated recording: a service loop over the core, per second. */
    private class Session(id: String, mode: RunMode, session: SessionSpec?) {
        val fs = FakeFileSystem()
        val writer = JournalWriter(fs, id, onWriteFailed = { throw it })
        val ticker = SampleTicker(wall = { wall })
        val core = RecorderCore(mode, session)
        private val id = id
        var t = T0
        var wall = W0

        init {
            fs.mkdirs(RunPaths.RUNS_DIR)
            writer.open()
            writer.append(JournalLine.Header(T0, W0, id, "contract-fixture", "core-jvm-test", "Australia/Sydney", mode, session, Units.km))
            emit(core.start(T0))
        }

        fun emit(out: List<RecorderCore.Output>) {
            for (o in out) {
                when (o) {
                    is RecorderCore.Output.Lap -> writer.append(JournalLine.Lap(o.t, wall, o.source))
                    is RecorderCore.Output.Cue -> writer.append(JournalLine.Cue(o.t, wall, o.kind))
                    is RecorderCore.Output.PhaseChanged -> Unit
                    is RecorderCore.Output.AutoStop -> autoStopped = true
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
            // As RecordingSession: sample first, so the core sees this second's distance.
            for (s in ticker.tick(t)) writer.append(s)
            emit(core.tick(t, ticker.distanceM, !ticker.gpsLost(t)))
        }

        /** The core asked to stop ([RecorderCore.Output.AutoStop]); the generator calls [finish]. */
        var autoStopped = false

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

    /** 60 s warmup, notification LAP, 4×4:00 @4.2 m/s with 3×3:00 @2.0 m/s between them, auto-lapped by the core, 60 s cooldown; HR by phase. */
    private fun fourByFourPresetAutoHr(): String {
        val preset = SessionSpec.norwegian4x4()
        val segments = ArrayList<Pair<Int, Double>>()
        segments.add(60 to 2.5)
        for (st in preset.steps) segments.add(st.value to if (st.kind == StepKind.work) 4.2 else 2.0)
        segments.add(60 to 2.5)
        val fixes = TraceFixture.straightLine(segments, LAT0, LON0, 6.0, T0)
        val s = Session("contract-4x4-preset", RunMode.intervals, preset)
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

    /** A 3-rep 4x4 (3 × 4:00 / 2:30): 60 s warmup, button LAP, auto laps, 60 s cool-down (migration golden, eng-review W1). */
    private fun fourByFourThreeReps(): String {
        val spec = SessionSpec.norwegian4x4(reps = 3, workSeconds = 240, recoverySeconds = 150)
        val segments = ArrayList<Pair<Int, Double>>()
        segments.add(60 to 2.5)
        for (st in spec.steps) segments.add(st.value to if (st.kind == StepKind.work) 4.0 else 2.0)
        segments.add(60 to 2.5)
        val fixes = TraceFixture.straightLine(segments, LAT0, LON0, 6.0, T0)
        val s = Session("contract-4x4-3reps", RunMode.intervals, spec)
        for ((i, f) in fixes.withIndex()) {
            if (i == 0) continue
            val hr = when (s.core.phase) {
                Phase.work -> 160 + (i % 5)
                Phase.recovery -> 140
                else -> 128
            }
            s.second(f, hr) { if (i == 60) s.lap(LapSource.button) }
        }
        return s.finish()
    }

    /** Cooper 12-minute test: the Cooper spec in the header; I1 records it like Free (no laps). 12 min @ 3.4 m/s, HR 170. */
    private fun cooper12Min(): String {
        val fixes = TraceFixture.straightLine(listOf(720 to 3.4), LAT0, LON0, 5.0, T0)
        val s = Session("contract-cooper", RunMode.cooper, SessionSpec.COOPER)
        for ((i, f) in fixes.withIndex()) {
            if (i == 0) continue
            s.second(f, 165 + (i % 6)) { if (i == 400) s.lap(LapSource.button) } // ignored: no lap input
        }
        return s.finish()
    }

    /** Fartlek: a Laps run with the steps-empty fartlek spec; manual laps at 2:00, 2:30, 5:00, 5:45. */
    private fun fartlekLaps(): String {
        val fixes = TraceFixture.straightLine(listOf(120 to 2.8, 30 to 4.5, 150 to 2.8, 45 to 4.6, 135 to 2.8), LAT0, LON0, 5.0, T0)
        val s = Session("contract-fartlek", RunMode.laps, SessionSpec.FARTLEK)
        for ((i, f) in fixes.withIndex()) {
            if (i == 0) continue
            s.second(f, 150) { if (i == 120 || i == 150 || i == 300 || i == 345) s.lap(LapSource.button) }
        }
        return s.finish()
    }

    /**
     * 8 × 400 m with 200 m jog recoveries, recorded by the real core (I2 distance steps): 60 s
     * warm-up, button LAP, 400 m at 4 m/s and 200 m at 2 m/s (100 s each), auto laps where the
     * core crossed each target, 60 s cool-down. (The name keeps its I1 "shape" suffix; the Dart
     * pins read it by name.)
     */
    private fun eightBy400Shape(): String {
        val spec = SessionSpec(
            templateId = "400s", templateVersion = 1, name = "8 × 400 m",
            warmupSeconds = null, cooldownSeconds = null, lapLockout = false, cueProfile = CueProfile.standard, hrBand = null,
            steps = (1..8).flatMap { r ->
                listOfNotNull(
                    Step(StepKind.work, TargetKind.distance, 400, RecoveryStyle.run, r),
                    if (r < 8) Step(StepKind.recovery, TargetKind.distance, 200, RecoveryStyle.jog, r) else null,
                )
            },
        )
        val segments = ArrayList<Pair<Int, Double>>()
        segments.add(60 to 2.5)
        for (st in spec.steps) segments.add(100 to if (st.kind == StepKind.work) 4.0 else 2.0)
        segments.add(60 to 2.5)
        val fixes = TraceFixture.straightLine(segments, LAT0, LON0, 5.0, T0)
        val s = Session("contract-8x400-shape", RunMode.intervals, spec)
        for ((i, f) in fixes.withIndex()) {
            if (i == 0) continue
            val hr = when (s.core.phase) {
                Phase.work -> 160 + (i % 5)
                Phase.recovery -> 140
                else -> 130
            }
            s.second(f, hr) { if (i == 60) s.lap(LapSource.button) }
        }
        return s.finish()
    }

    /**
     * parkrun (K1 reuses I2): one 5000 m distance step with auto-stop. 120 s warm-up jog, button
     * LAP on the start line, 5 km at 4 m/s; the core stops the recording at 5.00 km (no lap on
     * the finish line: the stop ends the 5 km lap).
     */
    private fun parkrun5kAutoStop(): String {
        val spec = SessionSpec(
            templateId = "parkrun", templateVersion = 1, name = "parkrun",
            warmupSeconds = null, cooldownSeconds = null, lapLockout = false, autoStop = true, cueProfile = CueProfile.standard, hrBand = null,
            steps = listOf(Step(StepKind.work, TargetKind.distance, 5_000, RecoveryStyle.run, 1)),
        )
        val fixes = TraceFixture.straightLine(listOf(120 to 2.0, 1_400 to 4.0), LAT0, LON0, 5.0, T0)
        val s = Session("contract-parkrun", RunMode.intervals, spec)
        for ((i, f) in fixes.withIndex()) {
            if (i == 0) continue
            s.second(f, if (i > 120) 168 else 128) { if (i == 120) s.lap(LapSource.button) }
            if (s.autoStopped) break
        }
        check(s.autoStopped) { "parkrun fixture never auto-stopped" }
        return s.finish()
    }

    /** 30/30 × 10 on the short cue profile: 60 s warm-up, button LAP, 30 s @ 4.5 m/s / 30 s @ 2 m/s, 60 s cool-down. */
    private fun thirtyThirtyShort(): String {
        val spec = SessionSpec.norwegian4x4(10, 30, 30).copy(
            templateId = "30-30", name = "30/30 × 10", hrBand = null, cueProfile = CueProfile.short,
        )
        val segments = ArrayList<Pair<Int, Double>>()
        segments.add(60 to 2.5)
        for (st in spec.steps) segments.add(st.value to if (st.kind == StepKind.work) 4.5 else 2.0)
        segments.add(60 to 2.5)
        val fixes = TraceFixture.straightLine(segments, LAT0, LON0, 5.0, T0)
        val s = Session("contract-30-30", RunMode.intervals, spec)
        for ((i, f) in fixes.withIndex()) {
            if (i == 0) continue
            s.second(f, if (s.core.phase == Phase.work) 170 else 150) { if (i == 60) s.lap(LapSource.button) }
        }
        return s.finish()
    }

    /**
     * I5: a [ReplayScenarios] scenario recorded here as the emulator job records it through the
     * real service (same fixes, HR and presses, trace time shifted to [T0]); the job checks its
     * run file against this one. An auto-stop ends the run at that tick, as the service does.
     */
    private fun replayKind(kind: String): String {
        val sc = ReplayScenarios.create(kind) ?: error("no replay scenario $kind")
        val s = Session("replay-$kind", sc.mode, sc.spec)
        val driver = ReplayScenarios.Driver(
            s.core, s.ticker, sc.presses,
            onSamples = { for (x in it) s.writer.append(x) },
            onOutputs = { s.emit(it) },
        )
        val hr = sc.hr.iterator()
        var next = if (hr.hasNext()) hr.next() else null
        for (f in sc.fixes) {
            val t = T0 + f.t
            s.t = t
            s.wall = W0 + f.t
            while (next != null && next.t <= f.t) { // HR items come first, as ReplaySource orders them
                s.ticker.onHr(HrReading(T0 + next.t, next.bpm))
                next = if (hr.hasNext()) hr.next() else null
            }
            driver.step(f.copy(t = t), null)
            if (s.autoStopped) break
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
