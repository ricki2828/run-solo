package app.runsolo.core.run

import app.runsolo.core.fs.FakeFileSystem
import app.runsolo.core.journal.JournalCodec
import app.runsolo.core.journal.JournalLine
import app.runsolo.core.model.LapSource
import app.runsolo.core.model.RunMode
import app.runsolo.core.reconcile.Reconciler
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

/** PR #9 review P1-1: a Phase-1 orphan under runs/<id>/ must still be offered, and as `laps`. */
class JournalMigrationTest {
    private val fs = FakeFileSystem()
    private val w0 = 1_700_000_000_000L

    /** A real Phase-1 journal: schema 1, mode free, one manual lap, one sample. */
    private fun legacyJournal(id: String, dir: String = "${RunPaths.RUNS_DIR}/$id") {
        fs.mkdirs(dir)
        val v1 = """{"k":"hdr","schema":1,"t":1000,"w":$w0,"id":"$id","device":"Pixel 8","app":"0.1.0-debug","tz":"Australia/Sydney","mode":"free","preset":null,"units":"km"}"""
        val rest = listOf(
            JournalLine.Sample(2_000, w0 + 1000, -33.8, 151.2, null, 5.0, 3.0, 150),
            JournalLine.Lap(61_000, w0 + 60_000, LapSource.volumeKey),
        ).joinToString("") { JournalCodec.encode(it) + "\n" }
        fs.writeBytes("$dir/${RunPaths.JOURNAL_NAME}", (v1 + "\n" + rest).toByteArray())
    }

    @Test
    fun `legacy orphan is moved and then offered for recovery as laps`() {
        fs.mkdirs(RunPaths.RUNS_DIR)
        legacyJournal("phase1-run")
        fs.writeBytes(RunPaths.runFile("committed"), byteArrayOf(1)) // a run file next to it is untouched
        fs.mkdirs("${RunPaths.RUNS_DIR}/empty-dir") // no journal inside: not ours, left alone
        assertTrue(Reconciler(fs).orphans(w0 + 100_000, activeRunId = null).isEmpty(), "invisible before the migration")

        val moved = JournalMigration(fs).migrate()

        assertEquals(listOf(JournalMigration.Moved("phase1-run", "runs/phase1-run", "journals/phase1-run")), moved)
        assertTrue(fs.exists(RunPaths.journal("phase1-run")))
        assertFalse(fs.exists("runs/phase1-run/journal.ndjson"))
        assertTrue(fs.exists(RunPaths.runFile("committed")))
        assertTrue(fs.isDirectory("runs/empty-dir"))
        val orphan = Reconciler(fs).orphans(w0 + 100_000, activeRunId = null).single()
        assertEquals("phase1-run", orphan.runId)
        assertTrue(orphan.readable)
        assertEquals(RunMode.laps, orphan.mode) // schema-1 free is the lap-capable mode
        assertEquals(40_000, orphan.lastLineAgeMs)
        assertTrue(fs.ops.count { it == "fsyncDir" } >= 2, "both directories fsynced")
        // Second call: nothing left to do.
        assertTrue(JournalMigration(fs).migrate().isEmpty())
    }

    @Test
    fun `finalising the migrated orphan produces a schema-3 laps run file`() {
        fs.mkdirs(RunPaths.RUNS_DIR)
        legacyJournal("p1")
        JournalMigration(fs).migrate()
        val out = Finaliser(fs).finalise("p1", w0 + 100_000, activeRunId = null)
        assertTrue(out is Finaliser.Outcome.Done)
        val m = RunFile.readJson(fs.readBytes((out as Finaliser.Outcome.Done).path))
        assertEquals(3L, m["schema"])
        assertEquals("laps", m["mode"])
        assertEquals(2, (m["laps"] as List<*>).size)
    }

    @Test
    fun `target already present - legacy copy is kept beside it, never deleted`() {
        fs.mkdirs(RunPaths.RUNS_DIR)
        legacyJournal("dup")
        legacyJournal("dup", dir = RunPaths.journalDir("dup")) // already migrated once, then a kill replayed the old dir
        val moved = JournalMigration(fs).migrate()
        assertEquals("journals/dup-legacy", moved.single().to)
        assertTrue(fs.exists(RunPaths.journal("dup")))
        assertTrue(fs.exists(RunPaths.journal("dup-legacy")))
        assertEquals(setOf("dup", "dup-legacy"), Reconciler(fs).orphans(w0, activeRunId = null).map { it.runId }.toSet())
    }

    @Test
    fun `a kill after the first rename is finished by the next open`() {
        fs.mkdirs(RunPaths.RUNS_DIR)
        legacyJournal("a")
        legacyJournal("b")
        fs.mkdirs(RunPaths.JOURNALS_DIR)
        fs.rename("runs/a", "journals/a") // the first move done...
        fs.crashBefore = "rename" // ...and the process dies before the second
        try {
            JournalMigration(fs).migrate()
        } catch (_: FakeFileSystem.Crash) {
        }
        assertTrue(fs.exists(RunPaths.journal("a")) && fs.exists("runs/b/journal.ndjson"))
        JournalMigration(fs).migrate()
        assertTrue(fs.exists(RunPaths.journal("a")) && fs.exists(RunPaths.journal("b")))
        assertTrue(fs.list(RunPaths.RUNS_DIR).none { fs.isDirectory("runs/$it") })
    }
}
