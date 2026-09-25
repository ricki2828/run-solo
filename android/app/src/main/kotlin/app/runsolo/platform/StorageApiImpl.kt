package app.runsolo.platform

import android.content.Context
import android.util.Log
import app.runsolo.core.fs.JvmFileSystem
import app.runsolo.core.run.BackupBudget
import app.runsolo.record.RecorderService

/**
 * `StorageApi`: the Auto Backup budget (plan §4, W3). The sqflite index lives in the app's
 * `databases/` directory, which the static rules back up beside `files/runs/` and
 * `files/state/`; its size counts towards the budget but it is never moved.
 */
class StorageApiImpl(private val context: Context) : StorageApi {
    private val fs = JvmFileSystem(context.filesDir.toPath())
    private val budget = BackupBudget(fs)

    private fun dbBytes(): Long {
        val db = context.getDatabasePath(DB_NAME)
        return if (db.exists()) db.length() else 0L
    }

    override fun backupStatus(): BackupStatus {
        val s = budget.status(dbBytes())
        return BackupStatus(
            backedUpBytes = s.backedUpBytes,
            budgetBytes = s.budgetBytes,
            quotaBytes = s.quotaBytes,
            archivedRunCount = s.archivedRunCount.toLong(),
            overBudget = s.overBudget,
        )
    }

    override fun enforceBackupBudget(): List<String> {
        val active = (RecorderService.session ?: RecorderService.pending)?.runId
        val moved = budget.enforce(dbBytes(), activeRunId = active)
        if (moved.isNotEmpty()) Log.i(TAG, "archived ${moved.size} run(s) past the backup budget: $moved")
        return moved
    }

    companion object {
        private const val TAG = "RunSolo/storage"

        /** Must match the Dart store's sqflite database name. */
        const val DB_NAME = "runsolo.db"

    }
}
