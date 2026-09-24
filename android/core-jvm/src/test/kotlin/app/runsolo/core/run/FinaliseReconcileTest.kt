package app.runsolo.core.run

import app.runsolo.core.fs.FakeFileSystem
import app.runsolo.core.journal.JournalCodec
import app.runsolo.core.journal.JournalLine
import app.runsolo.core.model.LapSource
import app.runsolo.core.model.Preset
import app.runsolo.core.model.RunMode
import app.runsolo.core.model.Units
import app.runsolo.core.reconcile.IndexRow
import app.runsolo.core.reconcile.ReconcilePlan
import app.runsolo.core.reconcile.Reconciler
import app.runsolo.core.reconcile.RunFileRef
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertIs
import kotlin.test.assertTrue

/**
 * Plan §12 "Finalise + reconcile": kill at each boundary → exactly one indexed run.
 * The index here is an in-memory stand-in for the sqflite `run` table, applied the way the
 * Dart store must (INSERT OR IGNORE + UPDATE, idempotent).
 */
class FinaliseReconcileTest {
    private class Index {
        val rows = LinkedHashMap<String, IndexRow>()
        fun apply(plan: ReconcilePlan) {
            for (f in plan.index) rows.putIfAbsent(f.id, IndexRow(f.id, f.path, false)) // INSERT OR IGNORE
            for (id in plan.markMissing) rows[id] = rows[id]!!.copy(missing = true)
            for (f in plan.restore) rows[f.id] = IndexRow(f.id, f.path, false)
            for (f in plan.repath) rows[f.id] = rows[f.id]!!.copy(filePath = f.path)
        }

        fun insertAfterStop(ref: RunFileRef) {
            rows.putIfAbsent(ref.id, IndexRow(ref.id, ref.path, false))
            rows[ref.id] = rows[ref.id]!!.copy(filePath = ref.path) // UPDATE
        }
    }

    private val fs = FakeFileSystem()
    private val t0 = 1_000L
    private val w0 = 1_700_000_000_000L
    private val now = w0 + 60_000

    private fun writeJournal(id: String) {
        fs.mkdirs(RunPaths.journalDir(id))
        val lines = listOf(
            JournalLine.Header(t0, w0, id, "dev", "app", "UTC", RunMode.fourByFour, Preset.DEFAULT_4X4, Units.km),
            JournalLine.Sample(t0 + 1000, w0 + 1000, 0.0, 0.0, null, 5.0, null, null),
            JournalLine.Lap(t0 + 2000, w0 + 2000, LapSource.button),
            JournalLine.Sample(t0 + 3000, w0 + 3000, 0.0, 0.001, null, 5.0, null, null),
        )
        fs.openAppend(RunPaths.journal(id)).use { a -> for (l in lines) a.write((JournalCodec.encode(l) + "\n").toByteArray()) }
    }

    /** What the app does on open: sweep leftovers, finalise every orphan, reconcile, apply. */
    private fun appOpen(index: Index) {
        val rec = Reconciler(fs)
        val fin = Finaliser(fs)
        for (id in rec.sweepCommitted(activeRunId = null)) fin.finalise(id, now, activeRunId = null)
        for (o in rec.orphans(now, activeRunId = null)) fin.finalise(o.runId, now, activeRunId = null)
        index.apply(rec.reconcile(index.rows.values.toList()))
    }

    private fun assertExactlyOne(index: Index, id: String) {
        assertEquals(listOf(id), index.rows.keys.toList())
        val row = index.rows[id]!!
        assertFalse(row.missing)
        assertEquals(RunPaths.runFile(id), row.filePath)
        assertTrue(fs.exists(RunPaths.runFile(id)))
        assertFalse(fs.exists(RunPaths.runFileTmp(id)))
        assertFalse(fs.exists(RunPaths.journal(id)))
        assertFalse(fs.isDirectory(RunPaths.journalDir(id)))
        val m = RunFile.readJson(fs.readBytes(RunPaths.runFile(id)))
        assertEquals(id, m["id"])
        assertEquals(2, (m["laps"] as List<*>).size)
    }

    @Test
    fun `happy path - stop finalises and Dart indexes`() {
        writeJournal("r1")
        val out = Finaliser(fs).finalise("r1", now, activeRunId = null)
        assertIs<Finaliser.Outcome.Done>(out)
        assertTrue(out.fresh)
        assertEquals(listOf("writeBytes", "fsyncFile", "rename", "fsyncDir", "deleteRecursively"), fs.ops)
        val index = Index()
        index.insertAfterStop(RunFileRef("r1", out.path))
        appOpen(index)
        assertExactlyOne(index, "r1")
        assertEquals(w0 + 3000, java.time.Instant.parse(RunFile.readJson(fs.readBytes(out.path))["end"] as String).toEpochMilli())
    }

    @Test
    fun `kill before tmp write - journal is an orphan, finalised on open`() {
        writeJournal("r1")
        fs.crashBefore = "writeBytes"
        assertFailsWith<FakeFileSystem.Crash> { Finaliser(fs).finalise("r1", now, activeRunId = null) }
        val index = Index()
        val orphans = Reconciler(fs).orphans(now, activeRunId = null)
        assertEquals("r1", orphans.single().runId)
        assertEquals(RunMode.fourByFour, orphans.single().mode)
        assertEquals(57_000, orphans.single().lastLineAgeMs)
        appOpen(index)
        assertExactlyOne(index, "r1")
    }

    @Test
    fun `kill after tmp write before rename - tmp is discarded and rebuilt`() {
        writeJournal("r1")
        fs.crashBefore = "rename"
        assertFailsWith<FakeFileSystem.Crash> { Finaliser(fs).finalise("r1", now, activeRunId = null) }
        assertTrue(fs.exists(RunPaths.runFileTmp("r1")))
        assertEquals(emptyList(), Reconciler(fs).scan()) // a tmp is never a run
        val index = Index()
        appOpen(index)
        assertExactlyOne(index, "r1")
        appOpen(index) // idempotent
        assertExactlyOne(index, "r1")
    }

    @Test
    fun `kill after rename before journal delete and before index - swept, indexed once`() {
        writeJournal("r1")
        fs.crashBefore = "deleteRecursively"
        assertFailsWith<FakeFileSystem.Crash> { Finaliser(fs).finalise("r1", now, activeRunId = null) }
        assertTrue(fs.exists(RunPaths.runFile("r1")))
        assertTrue(fs.exists(RunPaths.journal("r1")))
        val before = fs.readBytes(RunPaths.runFile("r1"))
        val rec = Reconciler(fs)
        assertEquals(emptyList(), rec.orphans(now, activeRunId = null)) // committed → not an orphan
        assertEquals(listOf("r1"), rec.sweepCommitted(activeRunId = null))
        val index = Index()
        appOpen(index)
        assertExactlyOne(index, "r1")
        assertTrue(before.contentEquals(fs.readBytes(RunPaths.runFile("r1"))), "committed file is never rewritten")
    }

    @Test
    fun `kill after finalise before index - reconciler indexes the file`() {
        writeJournal("r1")
        Finaliser(fs).finalise("r1", now, activeRunId = null)
        val index = Index() // Dart never got to INSERT
        appOpen(index)
        assertExactlyOne(index, "r1")
    }

    @Test
    fun `kill after index - nothing to do, still exactly one`() {
        writeJournal("r1")
        val out = Finaliser(fs).finalise("r1", now, activeRunId = null) as Finaliser.Outcome.Done
        val index = Index()
        index.insertAfterStop(RunFileRef("r1", out.path))
        appOpen(index)
        appOpen(index)
        assertExactlyOne(index, "r1")
    }

    @Test
    fun `finalise is a no-op with nothing on disk and corrupt without a header`() {
        fs.mkdirs(RunPaths.RUNS_DIR)
        assertIs<Finaliser.Outcome.Nothing>(Finaliser(fs).finalise("nope", now, activeRunId = null))
        fs.mkdirs(RunPaths.journalDir("bad"))
        fs.openAppend(RunPaths.journal("bad")).use { it.write("{\"k\":\"s\",\"t\":1}\n".toByteArray()) }
        assertIs<Finaliser.Outcome.Corrupt>(Finaliser(fs).finalise("bad", now, activeRunId = null))
        val o = Reconciler(fs).orphans(now, activeRunId = null).single()
        assertFalse(o.readable)
    }

    @Test
    fun `unsafe ids are refused`() {
        assertFailsWith<IllegalArgumentException> { Finaliser(fs).finalise("../x", now, activeRunId = null) }
    }
}
