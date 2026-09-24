package app.runsolo.core.reconcile

import app.runsolo.core.fs.FakeFileSystem
import app.runsolo.core.run.RunPaths
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

class ReconcilerTest {
    private val fs = FakeFileSystem()

    private fun put(path: String) {
        fs.mkdirs(path.substringBeforeLast('/'))
        fs.writeBytes(path, byteArrayOf(1))
    }

    @Test
    fun `scan covers runs and runs-archive and ignores tmp sidecars and journal dirs`() {
        put("runs/run-a.json.gz")
        put("runs/run-a.edits.json")
        put("runs/run-b.json.gz.tmp")
        put("runs/c/journal.ndjson")
        put("runs-archive/run-d.json.gz")
        put("runs-archive/run-d.edits.json")
        put("runs/run-bad id.json.gz")
        assertEquals(
            listOf(RunFileRef("a", "runs/run-a.json.gz"), RunFileRef("d", "runs-archive/run-d.json.gz")),
            Reconciler(fs).scan(),
        )
    }

    @Test
    fun `plan - file without row is indexed, row without file is missing`() {
        put("runs/run-a.json.gz")
        val rec = Reconciler(fs)
        val plan = rec.reconcile(listOf(IndexRow("z", "runs/run-z.json.gz", false)))
        assertEquals(listOf(RunFileRef("a", "runs/run-a.json.gz")), plan.index)
        assertEquals(listOf("z"), plan.markMissing)
        assertTrue(plan.restore.isEmpty() && plan.repath.isEmpty())
        // Already-missing rows are not re-flagged; agreeing rows produce nothing.
        val plan2 = rec.reconcile(listOf(IndexRow("z", "x", true), IndexRow("a", "runs/run-a.json.gz", false)))
        assertTrue(plan2.isEmpty)
    }

    @Test
    fun `archive move interrupted after rename before UPDATE is repathed (R1)`() {
        put("runs-archive/run-a.json.gz")
        val plan = Reconciler(fs).reconcile(listOf(IndexRow("a", "runs/run-a.json.gz", false)))
        assertEquals(listOf(RunFileRef("a", "runs-archive/run-a.json.gz")), plan.repath)
        assertTrue(plan.markMissing.isEmpty())
    }

    @Test
    fun `a file that comes back clears missing`() {
        put("runs/run-a.json.gz")
        val plan = Reconciler(fs).reconcile(listOf(IndexRow("a", "runs/run-a.json.gz", true)))
        assertEquals(listOf(RunFileRef("a", "runs/run-a.json.gz")), plan.restore)
    }

    @Test
    fun `same id in both dirs counts once and runs wins`() {
        put("runs/run-a.json.gz")
        put("runs-archive/run-a.json.gz")
        assertEquals(listOf(RunFileRef("a", "runs/run-a.json.gz")), Reconciler(fs).scan())
    }

    @Test
    fun `orphans - unreadable journal is reported with file age`() {
        fs.clock = 5_000
        put(RunPaths.journal("x"))
        val o = Reconciler(fs).orphans(65_000, activeRunId = null).single()
        assertEquals("x", o.runId)
        assertEquals(60_000, o.lastLineAgeMs)
        assertEquals(false, o.readable)
    }

    @Test
    fun `run id parsing`() {
        assertEquals("abc-1", RunPaths.runIdFromFileName("run-abc-1.json.gz"))
        assertEquals(null, RunPaths.runIdFromFileName("run-abc-1.json.gz.tmp"))
        assertEquals(null, RunPaths.runIdFromFileName("run-.json.gz"))
        assertEquals(null, RunPaths.runIdFromFileName("run-a/b.json.gz"))
        assertEquals(null, RunPaths.runIdFromFileName("journal.ndjson"))
    }
}
