package app.runsolo.core.reconcile

import app.runsolo.core.fs.FileSystem
import app.runsolo.core.journal.JournalReplay
import app.runsolo.core.model.RunMode
import app.runsolo.core.run.RunPaths

/** A committed run file on disk. [path] is relative to `files/`. */
data class RunFileRef(val id: String, val path: String)

/** What the sqflite index knows about a run (plan §4 `run` table, the columns that matter here). */
data class IndexRow(val id: String, val filePath: String, val missing: Boolean)

/** A sidecar that is not beside its run file (an archive move interrupted between the two renames). */
data class SidecarMove(val id: String, val from: String, val to: String)

/**
 * The diff the store must apply. Every list is disjoint; applying all makes files and rows
 * agree. The store applies [index] with `INSERT OR IGNORE` + `UPDATE` (never UPSERT —
 * API 29 SQLite is 3.22), so applying the same plan twice is harmless. [moveSidecar] is a
 * filesystem rename the store does before touching rows.
 */
data class ReconcilePlan(
    /** File with no row at all → parse header, insert a row. */
    val index: List<RunFileRef>,
    /** Row whose file is gone from both `runs/` and `runs-archive/` → mark `missing`, keep the row. */
    val markMissing: List<String>,
    /** Row that says `missing` but the file is back (restore, import) → clear the flag. */
    val restore: List<RunFileRef>,
    /** Row whose `file_path` no longer matches where the file is (archive move interrupted) → fix the path. */
    val repath: List<RunFileRef>,
    /** Sidecar in a different directory from its run file → rename it next to the file. */
    val moveSidecar: List<SidecarMove> = emptyList(),
) {
    val isEmpty get() = index.isEmpty() && markMissing.isEmpty() && restore.isEmpty() && repath.isEmpty() && moveSidecar.isEmpty()
}

/** An in-progress journal with no committed run file (plan §3 `recover()`). */
data class OrphanJournal(
    val runId: String,
    val lastLineAgeMs: Long,
    val mode: RunMode,
    /** True when the journal decodes to a header; false → it can only be discarded. */
    val readable: Boolean,
)

/**
 * Files ↔ index, both ways (plan §2 rule 5, R1). Pure: [scan] reads the two run directories,
 * [plan] is a set difference, [orphans] finds journals to recover. Nothing here writes the
 * index — the Dart store applies the plan — and nothing here deletes a run file, ever.
 *
 * The run being recorded is invisible to every method that takes `activeRunId`: the service
 * passes the id its `RecorderCore` owns (explicitly null when idle — there is no default, so a
 * caller cannot lose the guard by omission), and that journal is neither an orphan nor a leftover.
 */
class Reconciler(private val fs: FileSystem) {
    /** Committed run files in `runs/` and `runs-archive/`. A file present in both counts once, `runs/` wins. */
    fun scan(): List<RunFileRef> {
        val seen = LinkedHashMap<String, RunFileRef>()
        for (dir in listOf(RunPaths.RUNS_DIR, RunPaths.ARCHIVE_DIR)) {
            for (name in fs.list(dir)) {
                val id = RunPaths.runIdFromFileName(name) ?: continue
                seen.putIfAbsent(id, RunFileRef(id, "$dir/$name"))
            }
        }
        return seen.values.toList()
    }

    /** Sidecars by id → directory they sit in (`runs` or `runs-archive`); first hit wins. */
    private fun scanSidecars(): Map<String, String> {
        val out = LinkedHashMap<String, String>()
        for (dir in listOf(RunPaths.RUNS_DIR, RunPaths.ARCHIVE_DIR)) {
            for (name in fs.list(dir)) {
                val id = RunPaths.runIdFromSidecarName(name) ?: continue
                out.putIfAbsent(id, dir)
            }
        }
        return out
    }

    fun plan(files: List<RunFileRef>, rows: List<IndexRow>, sidecars: Map<String, String> = emptyMap()): ReconcilePlan {
        val byId = files.associateBy { it.id }
        val rowIds = rows.map { it.id }.toSet()
        val index = files.filter { it.id !in rowIds }
        val markMissing = ArrayList<String>()
        val restore = ArrayList<RunFileRef>()
        val repath = ArrayList<RunFileRef>()
        for (row in rows) {
            val f = byId[row.id]
            when {
                f == null -> if (!row.missing) markMissing.add(row.id)
                row.missing -> restore.add(f)
                row.filePath != f.path -> repath.add(f)
            }
        }
        val moves = ArrayList<SidecarMove>()
        for ((id, dir) in sidecars) {
            val f = byId[id] ?: continue
            val fileDir = f.path.substringBeforeLast('/')
            if (dir != fileDir) moves.add(SidecarMove(id, RunPaths.edits(id, dir), RunPaths.edits(id, fileDir)))
        }
        return ReconcilePlan(index, markMissing, restore, repath, moves)
    }

    /** Convenience: scan files + sidecars, then plan. */
    fun reconcile(rows: List<IndexRow>): ReconcilePlan = plan(scan(), rows, scanSidecars())

    /**
     * Journals under `runs/<id>/` with no committed run file, newest first. A journal whose run
     * file exists (kill after rename, before cleanup) is not an orphan —
     * [app.runsolo.core.run.Finaliser] cleans it up on its next call, which [sweepCommitted]
     * triggers. The active run is never listed.
     */
    fun orphans(nowEpochMs: Long, activeRunId: String?): List<OrphanJournal> {
        val committed = scan().map { it.id }.toSet()
        val out = ArrayList<OrphanJournal>()
        for (name in fs.list(RunPaths.RUNS_DIR)) {
            if (name == activeRunId) continue
            if (!RunPaths.isSafeId(name) || !fs.isDirectory("${RunPaths.RUNS_DIR}/$name")) continue
            val journal = RunPaths.journal(name)
            if (!fs.exists(journal) || name in committed) continue
            val replay = try {
                JournalReplay.read(fs.readBytes(journal))
            } catch (_: Exception) {
                null
            }
            val lastWall = replay?.lastWallMs?.takeIf { it > 0 } ?: fs.lastModifiedMs(journal) ?: nowEpochMs
            out.add(
                OrphanJournal(
                    runId = name,
                    lastLineAgeMs = (nowEpochMs - lastWall).coerceAtLeast(0),
                    mode = replay?.header?.mode ?: RunMode.free,
                    readable = replay != null,
                ),
            )
        }
        return out.sortedBy { it.lastLineAgeMs }
    }

    /** Journal directories whose run file is already committed: leftovers of a kill after rename. */
    fun sweepCommitted(activeRunId: String?): List<String> {
        val committed = scan().map { it.id }.toSet()
        return fs.list(RunPaths.RUNS_DIR).filter {
            it != activeRunId && it in committed && fs.isDirectory("${RunPaths.RUNS_DIR}/$it")
        }
    }
}
