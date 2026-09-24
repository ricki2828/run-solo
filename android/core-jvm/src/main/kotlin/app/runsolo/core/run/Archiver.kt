package app.runsolo.core.run

import app.runsolo.core.fs.FileSystem

/**
 * Moves a run past the backup budget into `runs-archive/` (plan §4, R1). Two files cannot be
 * renamed atomically together, so the order is fixed and the Reconciler repairs any kill in
 * between:
 *
 *   1. sidecar `run-<id>.edits.json` → archive   (if it exists)
 *   2. run file `run-<id>.json.gz` → archive      (the commit point: where the run file is, is truth)
 *   3. fsync the archive directory
 *   4. caller: `UPDATE run SET file_path` (a kill here → `repath`)
 *
 * A kill between 1 and 2 leaves the sidecar ahead of its file → the Reconciler's `moveSidecar`
 * puts it back beside the file in `runs/` (the file's directory wins, always). Calling
 * [archive] again after any kill finishes the job.
 */
class Archiver(private val fs: FileSystem) {
    data class Result(val id: String, val filePath: String, val movedFile: Boolean, val movedSidecar: Boolean)

    fun archive(runId: String): Result {
        require(RunPaths.isSafeId(runId)) { "unsafe run id" }
        fs.mkdirs(RunPaths.ARCHIVE_DIR)
        val edits = RunPaths.edits(runId)
        val editsTo = RunPaths.edits(runId, RunPaths.ARCHIVE_DIR)
        var movedSidecar = false
        if (fs.exists(edits)) {
            fs.rename(edits, editsTo)
            movedSidecar = true
        }
        val file = RunPaths.runFile(runId)
        val fileTo = RunPaths.runFile(runId, RunPaths.ARCHIVE_DIR)
        var movedFile = false
        if (fs.exists(file)) {
            fs.rename(file, fileTo)
            movedFile = true
        }
        fs.fsyncDir(RunPaths.ARCHIVE_DIR)
        fs.fsyncDir(RunPaths.RUNS_DIR)
        return Result(runId, fileTo, movedFile, movedSidecar)
    }
}
