package app.runsolo.core.run

import app.runsolo.core.fs.FakeFileSystem
import app.runsolo.core.reconcile.IndexRow
import app.runsolo.core.reconcile.Reconciler
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

/** Plan §4 W3 / §12: overflow moves the oldest files (file + sidecar) to `runs-archive/`; the Reconciler agrees afterwards. */
class BackupBudgetTest {
    private val fs = FakeFileSystem()

    private fun run(id: String, bytes: Int, mtime: Long, sidecarBytes: Int = 0) {
        fs.mkdirs(RunPaths.RUNS_DIR)
        fs.clock = mtime
        fs.writeBytes(RunPaths.runFile(id), ByteArray(bytes))
        if (sidecarBytes > 0) fs.writeBytes(RunPaths.edits(id), ByteArray(sidecarBytes))
    }

    @Test
    fun `under budget - nothing moves, status reports the backed-up total`() {
        run("a", 100, 1_000, sidecarBytes = 20)
        run("b", 200, 2_000)
        val b = BackupBudget(fs, budgetBytes = 1_000)
        assertEquals(emptyList(), b.plan(dbBytes = 500))
        val st = b.status(dbBytes = 500)
        assertEquals(820, st.backedUpBytes)
        assertFalse(st.overBudget)
        assertEquals(0, st.archivedRunCount)
        assertEquals(BackupBudget.QUOTA_BYTES, st.quotaBytes)
    }

    @Test
    fun `over budget - oldest first until it fits, sidecar travels, journals and archive untouched`() {
        run("old", 400, 1_000, sidecarBytes = 50)
        run("mid", 300, 2_000)
        run("new", 300, 3_000, sidecarBytes = 10)
        fs.mkdirs(RunPaths.journalDir("live"))
        fs.writeBytes(RunPaths.journal("live"), ByteArray(5_000)) // never counted, never moved
        val b = BackupBudget(fs, budgetBytes = 700)
        // db 100 + 450 + 300 + 310 = 1160 > 700 → drop old (710), drop mid (410) ≤ 700.
        assertEquals(listOf("old", "mid"), b.plan(dbBytes = 100))
        assertEquals(listOf("old", "mid"), b.enforce(dbBytes = 100, activeRunId = "live"))
        assertTrue(fs.exists(RunPaths.runFile("old", RunPaths.ARCHIVE_DIR)))
        assertTrue(fs.exists(RunPaths.edits("old", RunPaths.ARCHIVE_DIR)))
        assertFalse(fs.exists(RunPaths.runFile("old")))
        assertFalse(fs.exists(RunPaths.edits("old")))
        assertTrue(fs.exists(RunPaths.runFile("mid", RunPaths.ARCHIVE_DIR)))
        assertTrue(fs.exists(RunPaths.runFile("new")))
        assertTrue(fs.exists(RunPaths.edits("new")))
        assertTrue(fs.exists(RunPaths.journal("live")))
        val st = b.status(dbBytes = 100)
        assertEquals(410, st.backedUpBytes)
        assertEquals(2, st.archivedRunCount)
        assertFalse(st.overBudget)
        // Second call is a no-op.
        assertEquals(emptyList(), b.enforce(dbBytes = 100, activeRunId = null))
        // Reconcile after overflow (R1): the rows only need a repath; nothing is missing, nothing duplicated.
        val plan = Reconciler(fs).reconcile(
            listOf("old", "mid", "new").map { IndexRow(it, RunPaths.runFile(it), false) },
        )
        assertEquals(listOf("runs-archive/run-old.json.gz", "runs-archive/run-mid.json.gz"), plan.repath.map { it.path })
        assertTrue(plan.markMissing.isEmpty() && plan.index.isEmpty() && plan.moveSidecar.isEmpty())
        assertEquals(3, Reconciler(fs).scan().size)
    }

    @Test
    fun `the database alone over budget - nothing to move, still reported over`() {
        run("a", 10, 1_000)
        val b = BackupBudget(fs, budgetBytes = 100)
        assertEquals(listOf("a"), b.plan(dbBytes = 500))
        b.enforce(dbBytes = 500, activeRunId = null)
        assertTrue(b.status(dbBytes = 500).overBudget)
        assertEquals(500, b.status(dbBytes = 500).backedUpBytes)
    }

    @Test
    fun `ties on mtime archive by id so the order is deterministic`() {
        run("b", 100, 1_000)
        run("a", 100, 1_000)
        run("c", 100, 1_000)
        assertEquals(listOf("a", "b"), BackupBudget(fs, budgetBytes = 100).plan(dbBytes = 0))
    }
}
