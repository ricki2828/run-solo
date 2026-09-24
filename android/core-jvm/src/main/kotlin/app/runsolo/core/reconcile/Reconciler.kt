package app.runsolo.core.reconcile

import app.runsolo.core.fs.FileSystem
import app.runsolo.core.journal.JournalReplay
import app.runsolo.core.model.RunMode
import app.runsolo.core.run.RunPaths

/** A committed run file on disk. [path] is relative to `files/`. */
data class RunFileRef(val id: String, val path: String)

/** What the sqflite index knows about a run (plan §4 `run` table, the columns that matter here). */
data class IndexRow(val id: String, val filePath: String, val missing: Boolean)

/**
 * The diff the store must apply. Every list is disjoint; applying all four makes files and
 * rows agree. The store applies [index] with `INSERT OR IGNORE` + `UPDATE` (never UPSERT —
 * API 29 SQLite is 3.22), so applying the same plan twice is harmless.
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
) {
    val isEmpty get() = index.isEmpty() && markMissing.isEmpty() && restore.isEmpty() && repath.isEmpty()
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

    fun plan(files: List<RunFileRef>, rows: List<IndexRow>): ReconcilePlan {
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
        return ReconcilePlan(index, markMissing, restore, repath)
    }

    /** Convenience: scan + plan. */
    fun reconcile(rows: List<IndexRow>): ReconcilePlan = plan(scan(), rows)

    /**
     * Journals under `runs/<id>/` with no committed run file. A journal whose run file exists
     * (kill after rename, before cleanup) is not an orphan — [app.runsolo.core.run.Finaliser]
     * cleans it up on its next call, which [sweepCommitted] triggers.
     */
    fun orphans(nowEpochMs: Long): List<OrphanJournal> {
        val committed = scan().map { it.id }.toSet()
        val out = ArrayList<OrphanJournal>()
        for (name in fs.list(RunPaths.RUNS_DIR)) {
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
        return out
    }

    /** Journal directories whose run file is already committed: leftovers of a kill after rename. */
    fun sweepCommitted(): List<String> {
        val committed = scan().map { it.id }.toSet()
        return fs.list(RunPaths.RUNS_DIR).filter {
            it in committed && fs.isDirectory("${RunPaths.RUNS_DIR}/$it")
        }
    }
}
