package app.runsolo.core.facade

import app.runsolo.core.fs.AppleFileSystem
import app.runsolo.core.gps.MovingDetector
import app.runsolo.core.journal.JournalLine
import app.runsolo.core.journal.JournalReplay
import app.runsolo.core.journal.JournalWriter
import app.runsolo.core.json.Json
import app.runsolo.core.model.HrReading
import app.runsolo.core.model.LapSource
import app.runsolo.core.model.LocationFix
import app.runsolo.core.model.RunMode
import app.runsolo.core.model.SessionSpec
import app.runsolo.core.model.Units
import app.runsolo.core.record.RecorderCore
import app.runsolo.core.record.SampleTicker
import app.runsolo.core.replay.ReplayScenarios
import app.runsolo.core.run.Finaliser
import app.runsolo.core.run.RunPaths

/**
 * One live recording for the Swift `RecorderHost` (iOS plan §2, P3, B1): the same pipeline as
 * [app.runsolo.core.replay.ReplayRun] and `ReplayScenarios.Driver` (ticker -> core -> journal ->
 * finaliser), split into the calls a 1 Hz host makes. Primitives and JSON strings only, so the
 * ObjC header stays plain. Not thread-safe: Swift calls it from one serial queue.
 *
 * Per second the host calls [onHr] / [onFix] for what arrived, any presses, then [tick]. The
 * order matches the Driver, so a scenario fed through here journals the same lines and the
 * finalised run file equals the contract fixture (RunnerTests/RecorderHostTests).
 */
class LiveRecorder(rootDir: String) {
    private val fs = AppleFileSystem(rootDir)
    private var core: RecorderCore? = null
    private var ticker: SampleTicker? = null
    private var writer: JournalWriter? = null
    private var moving: MovingDetector? = null
    private var wall = 0L
    private var lastT = 0L
    private var autoStopped = false
    private var lastWriteError: String? = null

    var runId: String? = null
        private set

    val active: Boolean get() = core != null

    /** Starts a run. [specJson] is the core's `SessionSpec.toJson()` shape (null: no session). */
    @Throws(Exception::class)
    fun start(runId: String, mode: String, specJson: String?, units: String, device: String, app: String, tz: String, t: Long, w: Long) {
        val spec = specJson?.let { SessionSpec.fromJson(Json.parse(it) as? Map<String, Any?>) }
        begin(runId, RunMode.valueOf(mode), spec, Units.valueOf(units), device, app, tz, t, w)
    }

    /** Starts a run with a [ReplayScenarios] kind's mode and session. */
    @Throws(Exception::class)
    fun startScenario(kind: String, runId: String, device: String, app: String, tz: String, t: Long, w: Long) {
        val sc = ReplayScenarios.create(kind) ?: throw IllegalArgumentException("no replay scenario $kind")
        begin(runId, sc.mode, sc.spec, Units.km, device, app, tz, t, w)
    }

    private fun begin(id: String, mode: RunMode, spec: SessionSpec?, units: Units, device: String, app: String, tz: String, t: Long, w: Long) {
        check(core == null) { "already recording $runId" }
        require(RunPaths.isSafeId(id)) { "unsafe run id" }
        fs.mkdirs(RunPaths.RUNS_DIR)
        val c = RecorderCore(mode, spec)
        wall = w
        lastT = t
        autoStopped = false
        lastWriteError = null
        val jw = JournalWriter(fs, id, onWriteFailed = { lastWriteError = it.message ?: it.toString() })
        jw.open()
        jw.append(JournalLine.Header(t, w, id, device, app, tz, mode, spec, units))
        core = c
        writer = jw
        ticker = SampleTicker(wall = { wall })
        moving = MovingDetector.forAutoPause(mode)
        runId = id
        emit(c.start(t), ArrayList())
    }

    /** NaN for [altM] / [speedMps] means the platform gave none. */
    fun onFix(t: Long, w: Long, lat: Double, lon: Double, altM: Double, accuracyM: Double, speedMps: Double) {
        val tk = ticker ?: return
        wall = w
        tk.onFix(LocationFix(t, lat, lon, altM.takeUnless { it.isNaN() }, accuracyM, speedMps.takeUnless { it.isNaN() }))
    }

    fun onHr(t: Long, bpm: Int) {
        ticker?.onHr(HrReading(t, bpm))
    }

    /** A LAP press; returns the core's decision name (`accepted`, `ignoredDebounce`, ...). */
    fun lap(source: String, t: Long, w: Long): String {
        val c = core ?: return RecorderCore.LapDecision.ignoredIdle.name
        wall = w
        val (decision, out) = c.lap(LapSource.valueOf(source), t)
        pendingEvents.addAll(emit(out, ArrayList()))
        return decision.name
    }

    fun startReps(t: Long, w: Long): String {
        val c = core ?: return RecorderCore.LapDecision.ignoredIdle.name
        wall = w
        val (decision, out) = c.startReps(t)
        pendingEvents.addAll(emit(out, ArrayList()))
        return decision.name
    }

    /** As `RecordingSession.pause` and the Driver: the core and the ticker stop measuring. */
    fun pause(t: Long, w: Long) {
        val c = core ?: return
        wall = w
        c.pause(t)
        ticker?.onPause()
        writer?.append(JournalLine.Pause(t, w))
    }

    fun resume(t: Long, w: Long) {
        val c = core ?: return
        wall = w
        pendingEvents.addAll(emit(c.resume(t), ArrayList()))
        ticker?.onResume()
        writer?.append(JournalLine.Resume(t, w))
    }

    private val pendingEvents = ArrayList<Map<String, Any?>>()

    /**
     * The 1 Hz step: journal this second's samples, advance the core, run auto-pause. Returns
     * `{"events": [...], "autoStopped": bool}`; events include those of presses since the last tick.
     */
    fun tick(t: Long, w: Long): String {
        val c = core ?: return "{\"events\":[],\"autoStopped\":false}"
        val tk = ticker!!
        wall = w
        lastT = t
        val events = ArrayList<Map<String, Any?>>(pendingEvents)
        pendingEvents.clear()
        val samples = tk.tick(t)
        for (s in samples) writer?.append(s)
        emit(c.tick(t, tk.distanceM, !tk.gpsLost(t)), events)
        val last = samples.lastOrNull()
        val md = moving!!
        if (last != null && last.hasFix) {
            val was = md.moving
            val now = md.update(last.t, tk.moveDistanceM, last.speedMps, last.lat, last.lon)
            if (was && !now) {
                if (c.autoPause(t)) { tk.onAutoPause(); writer?.append(JournalLine.AutoPause(t, w)); events.add(mapOf("type" to "autoPause", "t" to t)) }
            } else if (!was && now) {
                if (c.autoResume(t)) { tk.onAutoResume(); writer?.append(JournalLine.AutoResume(t, w)); events.add(mapOf("type" to "autoResume", "t" to t)) }
            }
        }
        return Json.write(mapOf("events" to events, "autoStopped" to autoStopped))
    }

    private fun emit(out: List<RecorderCore.Output>, into: ArrayList<Map<String, Any?>>): ArrayList<Map<String, Any?>> {
        for (o in out) when (o) {
            is RecorderCore.Output.Lap -> {
                writer?.append(JournalLine.Lap(o.t, wall, o.source))
                into.add(mapOf("type" to "lap", "t" to o.t, "index" to o.index, "source" to o.source.name))
            }
            is RecorderCore.Output.Cue -> {
                writer?.append(JournalLine.Cue(o.t, wall, o.kind))
                into.add(mapOf("type" to "cue", "t" to o.t, "kind" to o.kind.name, "value" to o.value, "index" to o.index))
            }
            is RecorderCore.Output.PhaseChanged ->
                into.add(mapOf("type" to "phase", "t" to o.t, "phase" to o.phase.name, "repIndex" to o.repIndex, "phaseDurationMs" to o.phaseDurationMs))
            is RecorderCore.Output.AutoStop -> {
                autoStopped = true
                into.add(mapOf("type" to "autoStop", "t" to o.t))
            }
        }
        return into
    }

    /** The core's status at [t] as JSON (null fields kept), plus the journal's health. */
    fun statusJson(t: Long): String {
        val c = core ?: return Json.write(mapOf("state" to "idle"))
        val s = c.status(t)
        return Json.write(
            mapOf(
                "runId" to runId, "mode" to c.mode.name, "state" to s.state.name, "elapsedMs" to s.elapsedMs,
                "activeMs" to s.activeMs, "lapIndex" to s.lapIndex, "phase" to s.phase.name, "repIndex" to s.repIndex,
                "phaseRemainingMs" to s.phaseRemainingMs, "stepIndex" to s.stepIndex, "stepRemainingMs" to s.stepRemainingMs,
                "stepRemainingM" to s.stepRemainingM, "pausedAtElapsedMs" to c.pausedAtElapsedMs, "distanceM" to c.distanceM,
                "gpsOk" to (ticker?.gpsLost(t) == false), "journalOk" to (writer?.ok ?: true), "writeError" to lastWriteError,
            ),
        )
    }

    /** Ends the run and finalises it; returns the run file path relative to the root. */
    @Throws(Exception::class)
    fun stop(t: Long, w: Long): String? {
        val c = core ?: return null
        val id = runId!!
        wall = w
        emit(c.stop(t), ArrayList())
        writer?.close()
        clear()
        return finalise(id, w, null)
    }

    /** Drops the run without finalising, as a kill would (the journal stays for recovery). */
    fun abandon() {
        writer?.close()
        clear()
    }

    private fun clear() {
        core = null
        ticker = null
        writer = null
        moving = null
        runId = null
        pendingEvents.clear()
    }

    /** Journal -> run file; the path for a run file that now exists, null for nothing / active / corrupt. */
    @Throws(Exception::class)
    fun finalise(runId: String, nowMs: Long, activeRunId: String?): String? =
        when (val o = Finaliser(fs).finalise(runId, nowMs, activeRunId)) {
            is Finaliser.Outcome.Done -> o.path
            else -> null
        }

    fun discardJournal(runId: String) {
        if (runId == this.runId || !RunPaths.isSafeId(runId)) return
        fs.deleteRecursively(RunPaths.journalDir(runId))
    }

    /** Journals left behind by a kill, as JSON `[{runId, lastLineAgeMs, mode, readable, newer, endedPaused, elapsedMs}]`. */
    fun orphansJson(nowMs: Long): String {
        if (!fs.isDirectory(RunPaths.JOURNALS_DIR)) return "[]"
        val out = ArrayList<Map<String, Any?>>()
        for (name in fs.list(RunPaths.JOURNALS_DIR).sorted()) {
            val id = name.substringAfterLast('/')
            if (id == runId || !RunPaths.isSafeId(id)) continue
            val path = RunPaths.journal(id)
            if (!fs.exists(path)) continue
            val row = HashMap<String, Any?>()
            row["runId"] = id
            try {
                val r = JournalReplay.read(fs.readBytes(path))
                row["readable"] = true
                row["newer"] = false
                row["mode"] = r.header.mode.name
                row["endedPaused"] = r.isPaused
                row["elapsedMs"] = r.endT
                row["lastLineAgeMs"] = (nowMs - r.lastWallMs).coerceAtLeast(0)
            } catch (e: JournalReplay.NoHeader) {
                row["readable"] = false
                row["newer"] = e is JournalReplay.NewerJournal
                row["mode"] = RunMode.free.name
                row["endedPaused"] = false
                row["elapsedMs"] = 0L
                row["lastLineAgeMs"] = fs.lastModifiedMs(path)?.let { (nowMs - it).coerceAtLeast(0) } ?: 0L
            }
            out.add(row)
        }
        return Json.write(out)
    }

    companion object {
        /** A scenario's inputs for a Swift-driven replay: `{fixes: [[t, lat, lon, alt, acc, speed]], hr: [[t, bpm]], presses: [[atMs, press]]}`. */
        @Throws(Exception::class)
        fun scenarioScriptJson(kind: String): String {
            val sc = ReplayScenarios.create(kind) ?: throw IllegalArgumentException("no replay scenario $kind")
            return Json.write(
                mapOf(
                    "mode" to sc.mode.name,
                    "fixes" to sc.fixes.map { listOf(it.t, it.lat, it.lon, it.altM, it.accuracyM, it.speedMps) },
                    "hr" to sc.hr.map { listOf(it.t, it.bpm) },
                    "presses" to sc.presses.map { listOf(it.atMs, it.press.name) },
                ),
            )
        }
    }
}
