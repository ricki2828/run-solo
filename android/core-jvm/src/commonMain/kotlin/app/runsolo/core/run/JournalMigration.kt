package app.runsolo.core.run

import app.runsolo.core.fs.FileSystem

/**
 * One-shot, crash-safe move of Phase-1 journals (`runs/<id>/journal.ndjson`) into
 * `journals/<id>/` (plan §4: journals live outside the Auto Backup include). Runs at every app
 * open before `recover()`, so an orphan left by an update that landed mid-run is still offered
 * for recovery and the schema-1 `free` → `laps` journal mapping actually gets to run on it.
 *
 * Each directory is one atomic rename; a kill between two leaves the rest for the next open.
 * If the target already exists (the same id journaled again after a partial move) the legacy
 * directory is moved to `journals/<id>-legacy` instead: both are kept, nothing is ever deleted.
 * Directories under `runs/` that hold no journal are left alone (never ours to touch).
 */
class JournalMigration(private val fs: FileSystem) {
    data class Moved(val id: String, val from: String, val to: String)

    fun migrate(): List<Moved> {
        val out = ArrayList<Moved>()
        val legacy = fs.list(RunPaths.RUNS_DIR).filter { name ->
            RunPaths.isSafeId(name) && fs.isDirectory("${RunPaths.RUNS_DIR}/$name") &&
                fs.exists("${RunPaths.RUNS_DIR}/$name/${RunPaths.JOURNAL_NAME}")
        }
        if (legacy.isEmpty()) return out
        fs.mkdirs(RunPaths.JOURNALS_DIR)
        for (id in legacy) {
            val from = "${RunPaths.RUNS_DIR}/$id"
            var target = RunPaths.journalDir(id)
            if (fs.exists(target)) target = RunPaths.journalDir("$id$LEGACY_SUFFIX")
            if (fs.exists(target)) continue // both a current and a legacy copy already exist: leave it
            fs.rename(from, target)
            out.add(Moved(id, from, target))
        }
        fs.fsyncDir(RunPaths.JOURNALS_DIR)
        fs.fsyncDir(RunPaths.RUNS_DIR)
        return out
    }

    companion object {
        const val LEGACY_SUFFIX = "-legacy"
    }
}
