package app.runsolo.core.contract

import app.runsolo.core.journal.JournalCodec
import app.runsolo.core.journal.JournalLine
import app.runsolo.core.journal.JournalReplay
import app.runsolo.core.json.Json
import app.runsolo.core.model.LapSource
import app.runsolo.core.model.LocationFix
import app.runsolo.core.model.Preset
import app.runsolo.core.model.RunMode
import app.runsolo.core.model.Units
import app.runsolo.core.record.RecorderCore
import app.runsolo.core.replay.TraceFixture
import app.runsolo.core.run.RunFile
import java.io.File

/**
 * Kotlin→Dart contract fixtures: real `RunFile.fromReplay` output from journals written the
 * way the recorder writes them (RecorderCore drives the preset run, so laps and cues are the
 * machine's own). Checked into `src/test/fixtures/contract/` and copied verbatim into
 * `packages/run_engine/test/fixtures/contract/`; [ContractFixturesTest] fails when the
 * generator and the checked-in files drift, so the Dart side always tests the current shape.
 *
 * Regenerate: `java -cp <test classpath> app.runsolo.core.contract.ContractFixturesKt`.
 */
object ContractFixtures {
    const val DIR = "src/test/fixtures/contract"
    private const val T0 = 1_000_000L
    private const val W0 = 1_758_672_000_000L // 2025-09-24T00:00:00Z
    private const val LAT0 = -33.8688
    private const val LON0 = 151.2093

    fun all(): Map<String, RunFile> = linkedMapOf(
        "four_by_four_preset_auto_hr" to fourByFourPresetAutoHr(),
        "treadmill_no_fix_hr" to treadmillNoFixHr(),
        "gps_dropout_hr" to gpsDropoutHr(),
        "free_run_pause_manual_laps" to freeRunPauseManualLaps(),
    )

    fun json(f: RunFile): String = Json.write(f.toJson())

    private fun header(id: String, mode: RunMode, preset: Preset?) =
        JournalLine.Header(T0, W0, id, "contract-fixture", "core-jvm-test", "Australia/Sydney", mode, preset, Units.km)

    private fun build(lines: List<JournalLine>): RunFile {
        val bytes = lines.joinToString("") { JournalCodec.encode(it) + "\n" }.toByteArray()
        val replay = JournalReplay.read(bytes)
        return RunFile.fromReplay(replay, replay.lastWallMs)
    }

    private fun fixLine(f: LocationFix, hr: Int?) =
        JournalLine.Sample(f.t, W0 + (f.t - T0), f.lat, f.lon, f.altM, f.accuracyM, f.speedMps, hr)

    /** 60 s warmup, LAP, 4×(4:00 @ 4.2 m/s, 3:00 @ 2.0 m/s) auto-lapped by the core, 60 s cooldown; HR by phase. */
    private fun fourByFourPresetAutoHr(): RunFile {
        val preset = Preset.DEFAULT_4X4
        val segments = ArrayList<Pair<Int, Double>>()
        segments.add(60 to 2.5)
        repeat(preset.reps) { segments.add(preset.workSeconds to 4.2); segments.add(preset.recoverySeconds to 2.0) }
        segments.add(60 to 2.5)
        val fixes = TraceFixture.straightLine(segments, LAT0, LON0, 6.0, T0)
        val core = RecorderCore(RunMode.fourByFour, preset)
        val lines = ArrayList<JournalLine>()
        lines.add(header("contract-4x4-preset", RunMode.fourByFour, preset))
        core.start(T0)
        for (f in fixes) {
            val w = W0 + (f.t - T0)
            if (f.t == T0 + 60_000) {
                val (_, out) = core.lap(LapSource.notification, f.t)
                lines.addAll(outputs(out, w))
            }
            lines.addAll(outputs(core.tick(f.t), w))
            val hr = when (core.phase) {
                app.runsolo.core.model.Phase.work -> 165 + ((f.t / 1000) % 5).toInt()
                app.runsolo.core.model.Phase.recovery -> 145
                else -> 130
            }
            lines.add(fixLine(f, hr))
        }
        lines.addAll(outputs(core.stop(fixes.last().t), W0 + (fixes.last().t - T0)))
        return build(lines)
    }

    private fun outputs(out: List<RecorderCore.Output>, w: Long): List<JournalLine> = out.mapNotNull {
        when (it) {
            is RecorderCore.Output.Lap -> JournalLine.Lap(it.t, w, it.source)
            is RecorderCore.Output.Cue -> JournalLine.Cue(it.t, w, it.kind)
            is RecorderCore.Output.PhaseChanged -> null
        }
    }

    /** 10 min free run with no GPS fix at all, HR ramp 120→150, one manual lap at 5:00. */
    private fun treadmillNoFixHr(): RunFile {
        val lines = ArrayList<JournalLine>()
        lines.add(header("contract-treadmill", RunMode.free, null))
        for (s in 1..600) {
            val t = T0 + s * 1000L
            val w = W0 + s * 1000L
            if (s == 300) lines.add(JournalLine.Lap(t, w, LapSource.button))
            lines.add(JournalLine.Sample.noFix(t, w, 120 + (30 * s) / 600))
        }
        return build(lines)
    }

    /** 6 min at 3 m/s; fixes lost from 2:00 to 2:45 (no-fix ticks carry HR 150); the runner keeps moving. */
    private fun gpsDropoutHr(): RunFile {
        val fixes = TraceFixture.straightLine(listOf(360 to 3.0), LAT0, LON0, 7.0, T0)
        val lines = ArrayList<JournalLine>()
        lines.add(header("contract-gps-dropout", RunMode.free, null))
        for (f in fixes) {
            val s = (f.t - T0) / 1000
            val w = W0 + (f.t - T0)
            if (s in 120..165) lines.add(JournalLine.Sample.noFix(f.t, w, 150)) else lines.add(fixLine(f, 150))
        }
        return build(lines)
    }

    /** Free run, manual laps at 3:00 and 6:00, a 20 s standing pause at 4:30 (fixes keep coming, no HR strap). */
    private fun freeRunPauseManualLaps(): RunFile {
        val fixes = TraceFixture.straightLine(listOf(270 to 3.0, 20 to 0.0, 250 to 3.0), LAT0, LON0, 5.0, T0)
        val lines = ArrayList<JournalLine>()
        lines.add(header("contract-pause", RunMode.free, null))
        for (f in fixes) {
            val s = (f.t - T0) / 1000
            val w = W0 + (f.t - T0)
            if (s == 180L || s == 360L) lines.add(JournalLine.Lap(f.t, w, LapSource.button))
            if (s == 270L) lines.add(JournalLine.Pause(f.t, w))
            if (s == 290L) lines.add(JournalLine.Resume(f.t, w))
            lines.add(fixLine(f, null))
        }
        return build(lines)
    }

    fun write(dir: File = File(DIR)) {
        dir.mkdirs()
        for ((name, f) in all()) File(dir, "$name.json").writeText(json(f) + "\n")
    }
}

fun main() {
    ContractFixtures.write()
    println("wrote ${ContractFixtures.all().size} fixtures to ${ContractFixtures.DIR}")
}
