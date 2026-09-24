package app.runsolo.core.run

import app.runsolo.core.fs.FakeFileSystem
import app.runsolo.core.journal.JournalLine
import app.runsolo.core.journal.JournalWriter
import app.runsolo.core.model.LapSource
import app.runsolo.core.model.RunMode
import app.runsolo.core.model.Units
import app.runsolo.core.reconcile.IndexRow
import app.runsolo.core.reconcile.Reconciler
import app.runsolo.core.reconcile.SidecarMove
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertIs
import kotlin.test.assertTrue

/** Review P1-1 (active run untouched), P2-4 (sidecar travels with the file), P2-5 (power loss). */
class ActiveRunAndArchiveTest {
    private val fs = FakeFileSystem()
    private val w0 = 1_700_000_000_000L

    private fun header(id: String) = JournalLine.Header(0, w0, id, "d", "a", "UTC", RunMode.free, null, Units.km)
    private fun sample(t: Long) = JournalLine.Sample(t, w0 + t, 0.0, 0.0, null, 5.0, null, null)

    @Test
    fun `app open while recording - the live journal is not an orphan and finalise refuses it`() {
        fs.mkdirs(RunPaths.RUNS_DIR)
        val live = JournalWriter(fs, "live")
        live.open()
        live.append(header("live"))
        live.append(sample(1000))
        // An older, genuinely orphaned journal sits next to it.
        fs.mkdirs(RunPaths.journalDir("old"))
        fs.openAppend(RunPaths.journal("old")).use { a ->
            a.write((app.runsolo.core.journal.JournalCodec.encode(header("old")) + "\n").toByteArray())
        }
        val rec = Reconciler(fs)
        assertEquals(listOf("old"), rec.orphans(w0 + 5000, activeRunId = "live").map { it.runId })
        assertEquals(setOf("live", "old"), rec.orphans(w0 + 5000, activeRunId = null).map { it.runId }.toSet())
        val fin = Finaliser(fs)
        assertIs<Finaliser.Outcome.Active>(fin.finalise("live", w0 + 5000, activeRunId = "live"))
        assertTrue(fs.exists(RunPaths.journal("live")))
        assertEquals(emptyList(), fs.ops.filter { it.startsWith("delete") })
        // Recording continues and stop() still yields the whole run.
        live.append(JournalLine.Lap(2000, w0 + 2000, LapSource.button))
        live.append(sample(3000))
        live.close()
        val done = fin.finalise("live", w0 + 3000, activeRunId = null)
        assertIs<Finaliser.Outcome.Done>(done)
        assertTrue(done.fresh)
        val m = RunFile.readJson(fs.readBytes(done.path))
        assertEquals(2, (m["laps"] as List<*>).size)
        assertEquals(2, (m["samples"] as List<*>).size)
        assertEquals(emptyList(), rec.sweepCommitted(activeRunId = "live"))
    }

    @Test
    fun `archive moves the sidecar first then the file - a kill in between is repaired by the reconciler`() {
        fs.mkdirs(RunPaths.RUNS_DIR)
        fs.writeBytes(RunPaths.runFile("a"), byteArrayOf(1))
        fs.writeBytes(RunPaths.edits("a"), byteArrayOf(2))
        fs.crashBefore = "rename"
        assertFailsWith<FakeFileSystem.Crash> { Archiver(fs).archive("a") }
        // Nothing moved yet: plan is empty apart from nothing.
        assertTrue(Reconciler(fs).reconcile(listOf(IndexRow("a", RunPaths.runFile("a"), false))).isEmpty)

        // Kill between the two renames: sidecar ahead of its file.
        fs.ops.clear()
        val fs2 = fs
        fs2.mkdirs(RunPaths.ARCHIVE_DIR)
        fs2.rename(RunPaths.edits("a"), RunPaths.edits("a", RunPaths.ARCHIVE_DIR))
        val plan = Reconciler(fs2).reconcile(listOf(IndexRow("a", RunPaths.runFile("a"), false)))
        assertEquals(listOf(SidecarMove("a", "runs-archive/run-a.edits.json", "runs/run-a.edits.json")), plan.moveSidecar)
        assertTrue(plan.repath.isEmpty())
        // Or the archive simply finishes: sidecar already there, file follows, then UPDATE via repath.
        val r = Archiver(fs2).archive("a")
        assertTrue(r.movedFile)
        assertFalse(r.movedSidecar)
        val plan2 = Reconciler(fs2).reconcile(listOf(IndexRow("a", RunPaths.runFile("a"), false)))
        assertEquals(listOf("runs-archive/run-a.json.gz"), plan2.repath.map { it.path })
        assertTrue(plan2.moveSidecar.isEmpty())
        assertTrue(fs2.exists("runs-archive/run-a.edits.json"))
    }

    @Test
    fun `power loss at every finalise step never leaves an empty committed run file`() {
        val steps = listOf("writeBytes", "fsyncFile", "rename", "fsyncDir", "deleteRecursively")
        for (step in steps) {
            val fs = FakeFileSystem()
            fs.mkdirs(RunPaths.RUNS_DIR)
            fs.fsyncDir(RunPaths.RUNS_DIR)
            val w = JournalWriter(fs, "p")
            w.open()
            w.append(header("p"))
            w.append(sample(1000))
            w.close()
            fs.fsyncDir(RunPaths.journalDir("p"))
            fs.crashBefore = step
            assertFailsWith<FakeFileSystem.Crash> { Finaliser(fs).finalise("p", w0 + 1000) }
            fs.powerLoss()
            val committed = RunPaths.runFile("p")
            if (fs.exists(committed)) {
                assertTrue(fs.size(committed) > 0, "step $step: committed file must never be empty")
                RunFile.readJson(fs.readBytes(committed))
            } else {
                assertTrue(fs.exists(RunPaths.journal("p")), "step $step: journal survives until the file is durable")
                assertTrue(fs.size(RunPaths.journal("p")) > 0)
            }
            // Recovery finishes the job either way.
            val out = Finaliser(fs).finalise("p", w0 + 1000)
            assertIs<Finaliser.Outcome.Done>(out)
            assertTrue(fs.size(committed) > 0)
        }
    }

    @Test
    fun `power loss model - unsynced appends and unsynced renames are lost`() {
        fs.mkdirs("d")
        fs.fsyncDir("d")
        val a = fs.openAppend("d/f")
        a.write(byteArrayOf(1, 2))
        a.fsync()
        a.write(byteArrayOf(3))
        fs.fsyncDir("d")
        fs.rename("d/f", "d/g") // no fsyncDir after
        fs.powerLoss()
        assertTrue(fs.exists("d/f"))
        assertFalse(fs.exists("d/g"))
        assertEquals(2, fs.size("d/f"))
    }
}
