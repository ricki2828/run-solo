package app.runsolo.core.contract

import app.runsolo.core.fs.FakeFileSystem
import app.runsolo.core.gps.LivePace
import app.runsolo.core.journal.JournalLine
import app.runsolo.core.journal.JournalReplay
import app.runsolo.core.journal.JournalWriter
import app.runsolo.core.journal.RunEvent
import app.runsolo.core.json.Json
import app.runsolo.core.model.HrReading
import app.runsolo.core.model.LapSource
import app.runsolo.core.model.LocationFix
import app.runsolo.core.model.Phase
import app.runsolo.core.model.SessionSpec
import app.runsolo.core.model.StepKind
import app.runsolo.core.model.RecorderState
import app.runsolo.core.model.RunMode
import app.runsolo.core.model.Units
import app.runsolo.core.record.RecorderCore
import app.runsolo.core.record.SampleTicker
import app.runsolo.core.replay.TraceFixture
import app.runsolo.core.run.RunPaths
import java.io.File

/**
 * Kotlin→Dart contract fixture for the EventChannel: every `RecorderEvent` the recorder emits
 * plus a `status()` snapshot at each state/phase event, for a synthetic 4x4 with a 20 s pause
 * mid-rep 2 and a process kill + `resumeRecovered` mid-rep 3.
 *
 * Produced by the JVM harness that mirrors `RecordingSession` field for field: the same
 * core-jvm state machine (`RecorderCore`), sampler (`SampleTicker`), `LivePace`, journal and
 * `RecorderCore.restore` from the replayed journal after the kill. It is not captured from a
 * device: the Android session maps the same core outputs to the same Pigeon fields, so a
 * divergence there is a bug on the Android side, not in this file.
 *
 * NDJSON, one object per line: `{"t": <elapsedMs>, "kind": "tick|lap|phase|state|cue|fault|status", ...}`
 * with the Pigeon field names and enums as their Dart names; a cue line carries its kind as
 * `cue`, a fault line as `fault` (the `kind` key is the line type). Ticks are 1 Hz here (the
 * device emits ≤ 2 Hz).
 */
object EventTraceFixture {
    /** Own directory: the run-file contract tests glob `contract/` and must not see event traces. */
    const val DIR = "src/test/fixtures/contract-events"
    const val NAME = "events_4x4_pause_kill"
    private const val W0 = 1_758_672_000_000L
    private const val RUN_ID = "contract-events-4x4"

    /** The Pigeon `SessionSpec` field names (flat HR band, `repIndex`), as `EventTrace` logs them on the device. */
    fun pigeonShape(spec: SessionSpec): Map<String, Any?> = linkedMapOf(
        "templateId" to spec.templateId, "templateVersion" to spec.templateVersion, "name" to spec.name,
        "warmupSeconds" to spec.warmupSeconds, "cooldownSeconds" to spec.cooldownSeconds,
        "lapLockout" to spec.lapLockout, "autoStop" to spec.autoStop, "cueProfile" to spec.cueProfile.name,
        "hrBandLow" to spec.hrBand?.first, "hrBandHigh" to spec.hrBand?.second,
        "steps" to spec.steps.map { linkedMapOf("kind" to it.kind.name, "target" to it.target.name, "value" to it.value, "style" to it.style.name, "repIndex" to it.rep) },
    )

    fun generate(): String {
        val preset = SessionSpec.norwegian4x4()
        val segments = ArrayList<Pair<Int, Double>>()
        segments.add(60 to 2.5)
        for (st in preset.steps) segments.add(st.value to if (st.kind == StepKind.work) 4.2 else 2.0)
        segments.add(60 to 2.5)
        val fixes = TraceFixture.straightLine(segments, accuracyM = 6.0, startT = 0)
        // Scenario points on the trace timeline (seconds).
        val lapAt = 60
        val pauseAt = 60 + 240 + 180 + 90 // rep 2 work + 90 s
        val pauseSeconds = 20
        val killAt = 60 + 2 * 420 + pauseSeconds + 60 // rep 3 work + 60 s (trace time incl. the pause)
        val gapSeconds = 30

        val lines = StringBuilder()
        fun emit(kind: String, t: Long, fields: Map<String, Any?>) {
            val m = LinkedHashMap<String, Any?>()
            m["t"] = t
            m["kind"] = kind
            m.putAll(fields)
            lines.append(Json.write(m)).append('\n')
        }

        val fs = FakeFileSystem()
        fs.mkdirs(RunPaths.RUNS_DIR)
        var writer = JournalWriter(fs, RUN_ID, onWriteFailed = { throw it })
        var ticker = SampleTicker(wall = { W0 })
        var core = RecorderCore(RunMode.intervals, preset)
        val livePace = LivePace()
        val laps = ArrayList<Map<String, Any?>>()
        var lapStartT = 0L
        var lapStartActive = 0L
        var lapStartDist = 0.0
        var hrLast: Int? = null

        fun status(t: Long): Map<String, Any?> {
            val st = core.status(t)
            return linkedMapOf(
                "state" to st.state.name, "runId" to RUN_ID, "mode" to RunMode.intervals.name, "laps" to laps.toList(),
                "elapsedMs" to st.elapsedMs, "lapIndex" to st.lapIndex, "gpsFix" to !ticker.gpsLost(t), "hrConnected" to true,
                "phase" to st.phase.name, "repIndex" to st.repIndex, "phaseRemainingMs" to st.phaseRemainingMs,
                "spec" to pigeonShape(preset), "stepIndex" to st.stepIndex, "stepRemainingMs" to st.stepRemainingMs,
                "stepRemainingM" to st.stepRemainingM, "journalOk" to writer.ok,
            )
        }

        fun state(t: Long, state: RecorderState) {
            emit("state", core.status(t).elapsedMs, mapOf("state" to state.name, "runId" to RUN_ID, "phase" to core.phase.name))
            emit("status", core.status(t).elapsedMs, status(t))
        }

        val pendingOut = ArrayList<RecorderCore.Output>()
        var prevTickT = 0L
        var prevTickD = 0.0

        fun publishLap(o: RecorderCore.Output.Lap, distanceM: Double) {
            val st = core.status(o.t)
            val el = st.elapsedMs
            val lap = linkedMapOf<String, Any?>("index" to o.index, "tMs" to el, "activeMs" to (st.activeMs - lapStartActive), "distanceM" to distanceM, "source" to o.source.name)
            lapStartActive = st.activeMs
            laps.add(lap)
            lapStartT = o.t
            lapStartDist = distanceM
            emit("lap", el, lap)
        }

        fun publishPhase(o: RecorderCore.Output.PhaseChanged) {
            emit("phase", core.status(o.t).elapsedMs, mapOf("phase" to o.phase.name, "repIndex" to o.repIndex, "phaseDurationMs" to (o.phaseDurationMs ?: 0L)))
            emit("status", core.status(o.t).elapsedMs, status(o.t))
        }

        fun flushLaps(t: Long) {
            for (o in pendingOut) when (o) {
                is RecorderCore.Output.Lap -> publishLap(o, core.distanceAtTime(o.t, prevTickT, prevTickD, t, ticker.distanceM))
                is RecorderCore.Output.PhaseChanged -> publishPhase(o)
                else -> Unit
            }
            pendingOut.clear()
        }

        fun handle(out: List<RecorderCore.Output>, t: Long) {
            for (o in out) {
                when (o) {
                    is RecorderCore.Output.Lap -> {
                        writer.append(JournalLine.Lap(o.t, W0 + o.t, o.source))
                        // As RecordingSession: a manual lap goes out at the next tick, at its interpolated
                        // distance, and the phase change it caused waits with it (lap first).
                        if (o.source == LapSource.auto) publishLap(o, ticker.distanceM) else pendingOut.add(o)
                    }
                    is RecorderCore.Output.Cue -> {
                        writer.append(JournalLine.Cue(o.t, W0 + o.t, o.kind))
                        emit("cue", core.status(o.t).elapsedMs, linkedMapOf("cue" to o.kind.name, "value" to o.value))
                    }
                    is RecorderCore.Output.PhaseChanged -> if (pendingOut.isEmpty()) publishPhase(o) else pendingOut.add(o)
                    is RecorderCore.Output.AutoStop -> Unit // no auto-stop in this 4x4
                }
            }
        }

        fun tick(t: Long, fix: LocationFix?, hr: Int?) {
            hr?.let { ticker.onHr(HrReading(t - 200, it)) }
            fix?.let { ticker.onFix(it) }
            val samples = ticker.tick(t)
            for (s in samples) writer.append(s)
            flushLaps(t)
            handle(core.tick(t, ticker.distanceM, !ticker.gpsLost(t)), t)
            prevTickT = t
            prevTickD = ticker.distanceM
            val last = samples.last()
            val pace = if (last.hasFix) livePace.update(last.t, ticker.distanceM) else null
            hrLast = last.hr
            val st = core.status(t)
            emit(
                "tick", st.elapsedMs,
                linkedMapOf(
                    "elapsedMs" to st.elapsedMs, "lapElapsedMs" to (t - lapStartT), "lapDistanceM" to (ticker.distanceM - lapStartDist),
                    "lapPaceLiveSecPerKm" to pace, "totalDistanceM" to ticker.distanceM, "hr" to last.hr, "gpsAccuracyM" to last.accuracyM,
                    "state" to st.state.name, "phase" to st.phase.name, "repIndex" to st.repIndex, "phaseRemainingMs" to st.phaseRemainingMs,
                    "stepIndex" to st.stepIndex, "stepRemainingMs" to st.stepRemainingMs, "stepRemainingM" to st.stepRemainingM,
                ),
            )
        }

        fun hrFor(): Int = when (core.phase) {
            Phase.work -> 165
            Phase.recovery -> 145
            else -> 130
        }

        // ---- before the kill: device time == trace time ----
        writer.open()
        writer.append(JournalLine.Header(0, W0, RUN_ID, "contract-fixture", "core-jvm-test", "Australia/Sydney", RunMode.intervals, preset, Units.km))
        handle(core.start(0), 0)
        state(0, RecorderState.recording)
        var i = 1
        var paused = false
        while (i < killAt) {
            val t = i * 1000L
            val f = fixes[i]
            if (i == lapAt) handle(core.lap(LapSource.notification, t).second, t)
            if (i == pauseAt) {
                core.pause(t); ticker.onPause(); paused = true
                writer.append(JournalLine.Pause(t, W0 + t))
                state(t, RecorderState.paused)
            }
            if (i == pauseAt + pauseSeconds) {
                core.resume(t); ticker.onResume(); paused = false
                writer.append(JournalLine.Resume(t, W0 + t))
                state(t, RecorderState.recording)
            }
            // Standing still during the pause: the fix repeats the pause position.
            tick(t, if (paused) fixes[pauseAt].copy(t = t) else f.copy(t = t), hrFor())
            i++
        }
        writer.close()

        // ---- kill: nothing for gapSeconds; relaunch → JournalReplay → restore (what resumeRecovered does) ----
        val resumeDeviceT = 5_000L // new elapsedRealtime base after the relaunch
        writer = JournalWriter(fs, RUN_ID, onWriteFailed = { throw it })
        writer.open()
        writer.append(JournalLine.Gap(resumeDeviceT, W0 + (killAt + gapSeconds) * 1000L, gapSeconds * 1000L))
        // As RecordingSession.startResumed: restore from the journal including the gap line.
        val replayed = JournalReplay.read(fs.readBytes(RunPaths.journal(RUN_ID)))
        core = RecorderCore.restore(replayed, resumeDeviceT)
        ticker = SampleTicker(wall = { W0 })
        var seedPaused = false
        var lastLapDist = 0.0
        for (e in replayed.events) {
            when (e) {
                is RunEvent.Sample -> if (e.hasFix && !seedPaused) ticker.filter.offer(LocationFix(e.t, e.lat!!, e.lon!!, e.altM, e.accuracyM!!, e.speedMps))
                is RunEvent.Pause -> seedPaused = true
                is RunEvent.Resume -> { seedPaused = false; ticker.filter.reanchor() }
                is RunEvent.Lap -> lastLapDist = ticker.filter.totalM
                else -> Unit
            }
        }
        ticker.filter.reanchor()
        lapStartDist = lastLapDist
        prevTickT = resumeDeviceT
        prevTickD = ticker.distanceM
        val lastLapRunT = replayed.events.filterIsInstance<RunEvent.Lap>().last().t
        lapStartT = resumeDeviceT - (replayed.endT - lastLapRunT) // endT includes the gap
        // As RecordingSession: active time at the last lap = its run time minus pauses/gaps before it.
        var inactive = 0L
        var pauseStart: Long? = null
        for (e in replayed.events) {
            when (e) {
                is RunEvent.Pause -> if (pauseStart == null) pauseStart = e.t
                is RunEvent.Resume -> pauseStart?.let { inactive += e.t - it; pauseStart = null }
                is RunEvent.Gap -> inactive += e.endT - e.t
                is RunEvent.Lap -> lapStartActive = e.t - inactive
                else -> Unit
            }
        }
        livePace.reset()
        state(resumeDeviceT, RecorderState.recording)
        // Trace resumes where the runner is now: the runner kept running through the dark 30 s.
        var traceIdx = killAt + gapSeconds
        var dt = resumeDeviceT
        while (traceIdx < fixes.size) {
            dt += 1000
            tick(dt, fixes[traceIdx].copy(t = dt), hrFor())
            traceIdx++
        }
        flushLaps(dt)
        val out = core.stop(dt)
        for (o in out) if (o is RecorderCore.Output.Cue) emit("cue", core.status(dt).elapsedMs, linkedMapOf("cue" to o.kind.name, "value" to o.value))
        state(dt, RecorderState.finalising)
        writer.close()
        emit("state", core.status(dt).elapsedMs, mapOf("state" to RecorderState.idle.name, "runId" to RUN_ID, "phase" to Phase.none.name))
        return lines.toString()
    }

    fun write(dir: File = File(DIR)) {
        dir.mkdirs()
        File(dir, "$NAME.ndjson").writeText(generate())
    }
}

fun main() {
    EventTraceFixture.write()
    println("wrote ${EventTraceFixture.NAME}.ndjson")
}
