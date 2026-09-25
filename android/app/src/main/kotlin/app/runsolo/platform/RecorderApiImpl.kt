package app.runsolo.platform

import android.Manifest
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.location.LocationManager
import android.os.Build
import android.os.StatFs
import android.util.Log
import androidx.core.content.ContextCompat
import app.runsolo.BuildConfig
import app.runsolo.core.fs.JvmFileSystem
import app.runsolo.core.journal.JournalReplay
import app.runsolo.core.model.Preset as CorePreset
import app.runsolo.core.reconcile.Reconciler
import app.runsolo.core.run.Finaliser
import app.runsolo.core.run.JournalMigration
import app.runsolo.core.run.RunPaths
import app.runsolo.record.ExitDiagnostics
import app.runsolo.record.RecorderService
import app.runsolo.record.RecordingSession
import app.runsolo.record.ReplayRunner
import java.util.TimeZone
import java.util.UUID

/**
 * `RecorderApi` backed by [RecorderService]. Lives in the Activity so `start` runs while it is
 * visible (B2). Every method is idempotent (plan §2): the UI may be recreated mid-run.
 */
class RecorderApiImpl(private val context: Context) : RecorderApi {
    private val fs = JvmFileSystem(context.filesDir.toPath())
    private val prefs = context.getSharedPreferences(RecorderService.PREFS, Context.MODE_PRIVATE)

    private fun active(): RecordingSession? = RecorderService.session ?: RecorderService.pending

    private fun granted(p: String) = ContextCompat.checkSelfPermission(context, p) == PackageManager.PERMISSION_GRANTED

    /** Plan §3: fine (not approximate) location, system location on, ≥ 50 MB free. */
    private fun precondition(): StartError? {
        val fine = granted(Manifest.permission.ACCESS_FINE_LOCATION)
        val coarse = granted(Manifest.permission.ACCESS_COARSE_LOCATION)
        if (!fine && !coarse) return StartError.NO_FINE_PERMISSION
        if (!fine) return StartError.APPROXIMATE_ONLY
        val lm = context.getSystemService(Context.LOCATION_SERVICE) as LocationManager
        if (!lm.isLocationEnabled) return StartError.LOCATION_OFF
        val free = try {
            StatFs(context.filesDir.path).availableBytes
        } catch (_: Exception) {
            Long.MAX_VALUE
        }
        if (free < MIN_FREE_BYTES) return StartError.LOW_STORAGE
        return null
    }

    /** See [StartGuard]: a failed resume keeps the journal; only a brand-new run is discarded. */
    private fun begin(session: RecordingSession, startStep: (RecordingSession) -> Unit): StartResult =
        StartGuard.begin(
            session = session,
            register = { RecorderService.pending = it },
            startStep = startStep,
            launch = { launch(it) },
            log = { msg, e -> Log.e(TAG, msg, e) },
        )

    private fun launch(session: RecordingSession): StartResult {
        RecorderService.pending = session
        val intent = Intent(context, RecorderService::class.java).setAction(RecorderService.ACTION_START)
        try {
            ContextCompat.startForegroundService(context, intent)
        } catch (e: Exception) {
            // Android 14+ refuses a location FGS started from the background. A new run is discarded
            // (nothing recorded, no file); a resumed run keeps its journal for the next recover().
            Log.e(TAG, "startForegroundService failed", e)
            RecorderService.pending = null
            session.abortStart()
            return StartResult(runId = null, error = StartGuard.failureError(session, StartError.FGS_NOT_ALLOWED))
        }
        return StartResult(runId = session.runId, error = null)
    }

    private fun newSession(mode: RecordMode, preset: Preset?, units: Units, replay: ReplayRunner?): RecordingSession {
        val coreMode = mode.toCore()
        // Only the 4x4 carries a preset (plan §18.2); anything passed for another mode is dropped, not journaled.
        val corePreset = if (coreMode.usesPreset) preset?.toCore() ?: CorePreset.DEFAULT_4X4 else null
        return RecordingSession(context, UUID.randomUUID().toString(), coreMode, corePreset, units.toCore(), replay, volumeKeyLaps(coreMode))
    }

    /** The user's opt-in, defaulting per mode (W8: on only for Laps); the session still gates it on `mode.lapInput`. */
    internal fun volumeKeyLaps(mode: app.runsolo.core.model.RunMode): Boolean =
        prefs.getBoolean(RecorderService.PREF_VOLUME_KEY_LAPS, mode.volumeKeyLapsDefault)

    private fun startWith(mode: RecordMode, preset: Preset?, units: Units, replay: ReplayRunner?): StartResult {
        active()?.let { return StartResult(runId = it.runId, error = null) }
        precondition()?.let { return StartResult(runId = null, error = it) }
        val session = newSession(mode, preset, units, replay)
        return begin(session) {
            it.startNew(device = "${Build.MANUFACTURER} ${Build.MODEL}", app = BuildConfig.VERSION_NAME, tz = TimeZone.getDefault().id)
        }
    }

    override fun start(mode: RecordMode, preset: Preset?, units: Units): StartResult = startWith(mode, preset, units, null)

    override fun startReplay(mode: RecordMode, preset: Preset?, units: Units, replay: ReplayConfig): StartResult {
        if (!BuildConfig.REPLAY_ENABLED) return StartResult(runId = null, error = StartError.REPLAY_UNAVAILABLE)
        val corePreset = preset?.toCore() ?: CorePreset.DEFAULT_4X4
        val runner = ReplayRunner.create(context, replay.fixture, replay.speed, corePreset)
            ?: return StartResult(runId = null, error = StartError.REPLAY_UNAVAILABLE)
        return startWith(mode, preset, units, runner)
    }

    override fun resumeRecovered(runId: String): StartResult {
        active()?.let { return StartResult(runId = it.runId, error = if (it.runId == runId) null else StartError.ALREADY_RUNNING) }
        if (!RunPaths.isSafeId(runId) || !fs.exists(RunPaths.journal(runId))) return StartResult(runId = null, error = StartError.NO_SUCH_JOURNAL)
        val replayed = try {
            JournalReplay.read(fs.readBytes(RunPaths.journal(runId)))
        } catch (e: Exception) {
            // Includes NewerJournal: a journal from a newer app cannot be resumed here (and is never discarded).
            Log.w(TAG, "resume: unreadable journal $runId: $e")
            return StartResult(runId = null, error = StartError.NO_SUCH_JOURNAL)
        }
        precondition()?.let { return StartResult(runId = null, error = it) }
        val h = replayed.header
        val session = RecordingSession(context, runId, h.mode, h.preset, h.units, null, volumeKeyLaps(h.mode))
        return begin(session) { it.startResumed(replayed) }
    }

    override fun pause() {
        active()?.pause()
    }

    override fun resume() {
        active()?.resume()
    }

    override fun lap(source: LapSource) {
        active()?.lap(source.toCore())
    }

    override fun startReps() {
        active()?.startReps()
    }

    override fun stop(): String? {
        val svc = RecorderService.instance
        val path = if (svc != null && RecorderService.session != null) {
            svc.stopRun()
        } else {
            val s = active() ?: return null
            RecorderService.pending = null
            RecorderService.session = null
            s.stop()
        }
        return path?.let { RunPaths.runIdFromFileName(it.substringAfterLast('/')) }
    }

    override fun status(): RecorderStatus = active()?.status() ?: RecorderStatus(
        state = RecorderState.IDLE,
        runId = null,
        mode = RecordMode.FREE,
        laps = emptyList(),
        elapsedMs = 0,
        lapIndex = 0,
        gpsFix = false,
        hrConnected = false,
        phase = Phase.NONE,
        repIndex = 0,
        phaseRemainingMs = 0,
        preset = null,
        journalOk = true,
    )

    override fun recover(): List<OrphanJournal> {
        val now = System.currentTimeMillis()
        val activeId = active()?.runId
        // Phase-1 journals lived under runs/<id>/; move them first so they are offered too (one-shot, crash-safe).
        try {
            val moved = JournalMigration(fs).migrate()
            if (moved.isNotEmpty()) Log.i(TAG, "migrated ${moved.size} legacy journal(s): ${moved.map { it.id }}")
        } catch (e: Exception) {
            Log.w(TAG, "legacy journal migration failed: $e")
        }
        return Reconciler(fs).orphans(now, activeRunId = activeId).map { o ->
            var endedPaused = false
            var elapsed = 0L
            if (o.readable) {
                try {
                    val r = JournalReplay.read(fs.readBytes(RunPaths.journal(o.runId)))
                    endedPaused = r.isPaused
                    elapsed = r.endT
                } catch (_: Exception) {
                }
            }
            // Diagnose the kill now and cache it (W11): the prefs that anchor it are pruned at stop,
            // and run detail asks `exitDiagnosis(runId)` long after the run was finalised.
            ExitDiagnostics.cacheForRecovery(context, o.runId)
            OrphanJournal(
                runId = o.runId,
                lastLineAgeMs = o.lastLineAgeMs,
                mode = o.mode.toPigeon(),
                readable = o.readable,
                newer = o.newer,
                endedPaused = endedPaused,
                elapsedMs = elapsed,
            )
        }.also { Log.i(TAG, "recover: ${it.size} orphan(s) ${it.map { o -> o.runId }}") }
    }

    override fun finalise(runId: String): String? {
        if (!RunPaths.isSafeId(runId)) return null
        return when (val out = Finaliser(fs).finalise(runId, System.currentTimeMillis(), activeRunId = active()?.runId)) {
            is Finaliser.Outcome.Done -> out.path.also { Log.i(TAG, "finalised orphan $runId → $it") }
            is Finaliser.Outcome.Corrupt -> {
                Log.w(TAG, "finalise $runId: corrupt (${out.reason})")
                null
            }
            else -> null
        }
    }

    override fun discardJournal(runId: String) {
        if (!RunPaths.isSafeId(runId) || runId == active()?.runId) return
        if (fs.exists(RunPaths.runFile(runId)) || fs.exists(RunPaths.runFile(runId, RunPaths.ARCHIVE_DIR))) return
        val journal = RunPaths.journal(runId)
        if (fs.exists(journal)) {
            // A journal from a newer app is never discarded (plan §18.7 W6): a later build reads it.
            val newer = try {
                JournalReplay.read(fs.readBytes(journal))
                false
            } catch (_: JournalReplay.NewerJournal) {
                true
            } catch (_: Exception) {
                false
            }
            if (newer) {
                Log.w(TAG, "discardJournal $runId refused: written by a newer app")
                return
            }
        }
        fs.deleteRecursively(RunPaths.journalDir(runId))
    }

    override fun setCues(enabled: Boolean) {
        prefs.edit().putBoolean(RecorderService.PREF_CUES, enabled).apply()
        active()?.setCues(enabled)
    }

    override fun setVolumeKeyLaps(enabled: Boolean) {
        // commit(), not apply(): the next start() may come from a new process.
        prefs.edit().putBoolean(RecorderService.PREF_VOLUME_KEY_LAPS, enabled).commit()
    }

    override fun listRunFiles(): Map<String, String> = Reconciler(fs).scan().associate { it.id to it.path }

    override fun exitDiagnosis(runId: String): ExitDiagnosis = ExitDiagnostics.diagnose(context, runId)

    companion object {
        const val TAG = "RunSolo/api"
        const val MIN_FREE_BYTES = 50L * 1024 * 1024
    }
}
