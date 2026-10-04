package app.runsolo.core.run

import app.runsolo.core.fs.FileSystem

/**
 * Keeps the Auto Backup set under budget (plan §4, W3). Android backs up NOTHING once an app
 * passes its 25 MB quota, and the backup rules are static paths, so the app itself moves the
 * oldest run files (with their sidecars) from `runs/` into `runs-archive/` — still on the
 * device, still indexed, just not backed up — once `db + runs/ files + sidecars` passes
 * [budgetBytes] (~15 MB, well under the quota so a big run or a DB rebuild cannot tip it).
 *
 * The backed-up total counts EVERYTHING under `runs/` (the rule includes the directory, so a
 * `.tmp` or a stray subdirectory is backed up too), but only run files can be moved.
 *
 * "Oldest" is by the run file's modification time (the finalise moment; an import writes a
 * newer mtime, so an imported old run is archived last — acceptable, it is already exported).
 * The move itself is [Archiver]'s job; the Dart Reconciler then `repath`s the index rows.
 */
class BackupBudget(
    private val fs: FileSystem,
    private val budgetBytes: Long = DEFAULT_BUDGET_BYTES,
) {
    data class Status(
        /** Bytes the static rules would back up: db + `runs/` run files + sidecars. */
        val backedUpBytes: Long,
        val budgetBytes: Long,
        val quotaBytes: Long,
        val archivedRunCount: Int,
    ) {
        val overBudget: Boolean get() = backedUpBytes > budgetBytes
    }

    /** One backed-up run file in `runs/`, with the size of its sidecar folded in. */
    data class Entry(val id: String, val bytes: Long, val modifiedMs: Long)

    fun entries(): List<Entry> = fs.list(RunPaths.RUNS_DIR).mapNotNull { name ->
        val id = RunPaths.runIdFromFileName(name) ?: return@mapNotNull null
        val file = RunPaths.runFile(id)
        val edits = RunPaths.edits(id)
        val sidecar = if (fs.exists(edits)) fs.size(edits) else 0L
        Entry(id, fs.size(file) + sidecar, fs.lastModifiedMs(file) ?: 0L)
    }

    /** Bytes of every file under [dir], recursively. */
    fun dirBytes(dir: String): Long = fs.list(dir).sumOf { name ->
        val p = "$dir/$name"
        if (fs.isDirectory(p)) dirBytes(p) else fs.size(p)
    }

    fun status(dbBytes: Long): Status = Status(
        backedUpBytes = dbBytes + dirBytes(RunPaths.RUNS_DIR),
        budgetBytes = budgetBytes,
        quotaBytes = QUOTA_BYTES,
        archivedRunCount = fs.list(RunPaths.ARCHIVE_DIR).count { RunPaths.runIdFromFileName(it) != null },
    )

    /** Pure: which ids to archive, oldest first, until the set fits (the DB itself is never movable). */
    fun plan(dbBytes: Long, entries: List<Entry> = entries(), otherBytes: Long = dirBytes(RunPaths.RUNS_DIR) - entries.sumOf { it.bytes }): List<String> {
        var total = dbBytes + otherBytes + entries.sumOf { it.bytes }
        if (total <= budgetBytes) return emptyList()
        val out = ArrayList<String>()
        for (e in entries.sortedWith(compareBy<Entry> { it.modifiedMs }.thenBy { it.id })) {
            if (total <= budgetBytes) break
            out.add(e.id)
            total -= e.bytes
        }
        return out
    }

    /** Archives per [plan]; returns the ids moved. [activeRunId] is never touched (it has no file yet anyway). */
    fun enforce(dbBytes: Long, activeRunId: String?): List<String> {
        val archiver = Archiver(fs)
        val moved = ArrayList<String>()
        for (id in plan(dbBytes)) {
            if (id == activeRunId) continue
            if (archiver.archive(id).movedFile) moved.add(id)
        }
        return moved
    }

    companion object {
        const val QUOTA_BYTES = 25L * 1024 * 1024
        const val DEFAULT_BUDGET_BYTES = 15L * 1024 * 1024
    }
}
