package app.runsolo.core.run

import app.runsolo.core.fs.FileSystem
import app.runsolo.core.journal.JournalReplay
import app.runsolo.core.journal.Replay

/**
 * Journal → run file, owned by Kotlin (plan §2/§3, B3):
 *
 *   read journal → build RunFile → write `run-<id>.json.gz.tmp` → fsync → rename to
 *   `run-<id>.json.gz` → fsync dir → delete `runs/<id>/` (journal)
 *
 * Never touches the run that is being recorded: the service passes [activeRunId] (the id its
 * `RecorderCore` owns) and a request for it returns [Outcome.Active] untouched — `recover()`
 * runs on every app open, including an open while the foreground service is mid-run.
 *
 * Idempotent at every boundary, so `stop()`, `finalise(runId)` from the recovery dialog and
 * the Reconciler can all call it after a kill:
 *  - run file already exists and journal still there → journal is deleted, file kept
 *    (the rename was the commit point; never rebuild over a committed file)
 *  - only a tmp exists → it is discarded and rebuilt from the journal
 *  - no journal and no run file → [Outcome.Nothing]
 */
class Finaliser(private val fs: FileSystem) {
    sealed class Outcome {
        /** A run file now exists at [path]; [fresh] false when it was already committed. */
        data class Done(val runId: String, val path: String, val fresh: Boolean, val replay: Replay?) : Outcome()
        data class Corrupt(val runId: String, val reason: String) : Outcome()
        data class Nothing(val runId: String) : Outcome()

        /** The run is still being recorded; nothing was read, written or deleted. */
        data class Active(val runId: String) : Outcome()
    }

    fun finalise(runId: String, nowEpochMs: Long, activeRunId: String?): Outcome {
        require(RunPaths.isSafeId(runId)) { "unsafe run id" }
        if (runId == activeRunId) return Outcome.Active(runId)
        val journal = RunPaths.journal(runId)
        val target = RunPaths.runFile(runId)
        val tmp = RunPaths.runFileTmp(runId)
        val committed = fs.exists(target) || fs.exists(RunPaths.runFile(runId, RunPaths.ARCHIVE_DIR))
        if (committed) {
            // Kill landed after rename: just finish the cleanup.
            fs.delete(tmp)
            fs.deleteRecursively(RunPaths.journalDir(runId))
            return Outcome.Done(runId, if (fs.exists(target)) target else RunPaths.runFile(runId, RunPaths.ARCHIVE_DIR), fresh = false, replay = null)
        }
        if (!fs.exists(journal)) {
            fs.delete(tmp)
            return Outcome.Nothing(runId)
        }
        val replay = try {
            JournalReplay.read(fs.readBytes(journal))
        } catch (e: JournalReplay.NoHeader) {
            return Outcome.Corrupt(runId, e.message ?: "no header")
        }
        // End = wall time of the last journaled line, not "now": after a kill the run ended
        // when the process died, and a recovery dialog answered an hour later must not
        // stretch the run.
        val endEpoch = if (replay.lastWallMs > 0) replay.lastWallMs else nowEpochMs
        val file = RunFile.fromReplay(replay, endEpoch)
        fs.mkdirs(RunPaths.RUNS_DIR)
        fs.writeBytes(tmp, file.toGzipBytes())
        fs.fsyncFile(tmp)
        fs.rename(tmp, target)
        fs.fsyncDir(RunPaths.RUNS_DIR)
        fs.deleteRecursively(RunPaths.journalDir(runId))
        fs.fsyncDir(RunPaths.JOURNALS_DIR)
        return Outcome.Done(runId, target, fresh = true, replay = replay)
    }
}
