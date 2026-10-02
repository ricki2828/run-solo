package app.runsolo.core.spike

import app.runsolo.core.fs.FileSystem
import app.runsolo.core.journal.JournalLine
import app.runsolo.core.journal.JournalWriter
import app.runsolo.core.json.Json
import app.runsolo.core.model.HrReading
import app.runsolo.core.model.Units
import app.runsolo.core.record.RecorderCore
import app.runsolo.core.record.SampleTicker
import app.runsolo.core.replay.ReplayScenarios
import app.runsolo.core.run.Finaliser
import app.runsolo.core.run.RunFile
import app.runsolo.core.run.RunPaths

/**
 * K0 spike: ContractFixtures.replayKind (core-jvm test code) on a caller-supplied FileSystem, so
 * a Swift test can drive the real pipeline (ticker -> core -> journal -> finaliser -> gzip run file)
 * on disk and compare with the checked-in `replay_<kind>.json`. Same constants as the generator.
 */
object SpikeReplay {
    private const val T0 = 1_000_000L
    private const val W0 = 1_758_672_000_000L

    fun runFileJson(kind: String, fs: FileSystem): String {
        val sc = ReplayScenarios.create(kind) ?: throw IllegalArgumentException("no replay scenario $kind")
        val id = "replay-$kind"
        fs.mkdirs(RunPaths.RUNS_DIR)
        val writer = JournalWriter(fs, id, onWriteFailed = { throw it })
        var wall = W0
        val ticker = SampleTicker(wall = { wall })
        val core = RecorderCore(sc.mode, sc.spec)
        var autoStopped = false
        fun emit(out: List<RecorderCore.Output>) {
            for (o in out) when (o) {
                is RecorderCore.Output.Lap -> writer.append(JournalLine.Lap(o.t, wall, o.source))
                is RecorderCore.Output.Cue -> writer.append(JournalLine.Cue(o.t, wall, o.kind))
                is RecorderCore.Output.PhaseChanged -> Unit
                is RecorderCore.Output.AutoStop -> autoStopped = true
            }
        }
        writer.open()
        writer.append(JournalLine.Header(T0, W0, id, "contract-fixture", "core-jvm-test", "Australia/Sydney", sc.mode, sc.spec, Units.km))
        emit(core.start(T0))
        val driver = ReplayScenarios.Driver(
            core, ticker, sc.presses,
            onSamples = { for (x in it) writer.append(x) },
            onOutputs = { emit(it) },
            onPause = { t -> writer.append(JournalLine.Pause(t, W0 + (t - T0))) },
        )
        val hr = sc.hr.iterator()
        var next = if (hr.hasNext()) hr.next() else null
        var t = T0
        for (f in sc.fixes) {
            t = T0 + f.t
            wall = W0 + f.t
            while (next != null && next.t <= f.t) {
                ticker.onHr(HrReading(T0 + next.t, next.bpm))
                next = if (hr.hasNext()) hr.next() else null
            }
            driver.step(f.copy(t = t), null)
            if (autoStopped) break
        }
        emit(core.stop(t))
        writer.close()
        val done = Finaliser(fs).finalise(id, wall, activeRunId = null) as Finaliser.Outcome.Done
        return Json.write(RunFile.readJson(fs.readBytes(done.path)))
    }
}
