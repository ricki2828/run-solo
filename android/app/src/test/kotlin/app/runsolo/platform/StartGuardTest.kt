package app.runsolo.platform

import app.runsolo.core.fs.JvmFileSystem
import app.runsolo.core.journal.JournalCodec
import app.runsolo.core.journal.JournalLine
import app.runsolo.core.journal.JournalWriter
import app.runsolo.core.model.RunMode
import app.runsolo.core.model.Units
import app.runsolo.core.reconcile.Reconciler
import app.runsolo.core.run.RunPaths
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.nio.file.Files

/**
 * A resume whose start step throws must leave the recovered run's journal on disk and listed
 * by the next recover(); only a brand-new run may be discarded. The fake session does what
 * RecordingSession.discard()/suspend() do to the journal (delete vs close-and-keep).
 */
class StartGuardTest {
    // A real temp directory: the in-memory fake lives in core-jvm's test sources, not its jar.
    private val fs = JvmFileSystem(Files.createTempDirectory("runsolo-startguard"))

    private inner class FakeSession(override val runId: String, private val orphan: Boolean) : StartGuard.Session {
        val writer = JournalWriter(fs, runId)
        var discarded = false
        var suspended = false

        init {
            fs.mkdirs(RunPaths.RUNS_DIR)
            if (orphan) {
                // A journal a previous process left behind.
                fs.mkdirs(RunPaths.journalDir(runId))
                fs.openAppend(RunPaths.journal(runId)).use { a ->
                    a.write((JournalCodec.encode(JournalLine.Header(0, 1_700_000_000_000L, runId, "d", "a", "UTC", RunMode.free, null, Units.km)) + "\n").toByteArray())
                }
            }
        }

        override fun discard() {
            discarded = true
            writer.close()
            fs.deleteRecursively(RunPaths.journalDir(runId))
        }

        override fun suspend() {
            suspended = true
            writer.close()
        }
    }

    private var pending: FakeSession? = null
    private var launched = 0

    private fun <S : StartGuard.Session> run(session: S, onFailure: StartGuard.OnFailure, error: StartError, step: (S) -> Unit): StartResult =
        StartGuard.begin(
            session = session,
            register = { pending = it as FakeSession? },
            onFailure = onFailure,
            failureError = error,
            startStep = step,
            launch = { launched++; StartResult(runId = it.runId, error = null) },
        )

    @Test
    fun `resume start step throws - journal kept, pending cleared, recover lists it, typed error`() {
        val s = FakeSession("r1", orphan = true)
        val result = run(s, StartGuard.OnFailure.KEEP_JOURNAL, StartError.RESUME_FAILED) {
            it.writer.open()
            throw IllegalStateException("boom while resuming")
        }
        assertNull(result.runId)
        assertEquals(StartError.RESUME_FAILED, result.error)
        assertNull(pending)
        assertEquals(0, launched)
        assertTrue(s.suspended)
        assertFalse(s.discarded)
        assertTrue("journal must survive a failed resume", fs.exists(RunPaths.journal("r1")))
        val orphans = Reconciler(fs).orphans(1_700_000_100_000L, activeRunId = null)
        assertEquals(listOf("r1"), orphans.map { it.runId })
        assertTrue(orphans.single().readable)
    }

    @Test
    fun `new run start step throws - journal discarded, pending cleared, typed error`() {
        val s = FakeSession("n1", orphan = false)
        val result = run(s, StartGuard.OnFailure.DISCARD, StartError.START_FAILED) {
            it.writer.open()
            throw java.io.IOException("ENOSPC")
        }
        assertEquals(StartError.START_FAILED, result.error)
        assertNull(pending)
        assertTrue(s.discarded)
        assertFalse(fs.exists(RunPaths.journalDir("n1")))
        assertTrue(Reconciler(fs).orphans(0, activeRunId = null).isEmpty())
    }

    @Test
    fun `start step succeeds - session stays registered and is launched`() {
        val s = FakeSession("ok", orphan = false)
        val result = run(s, StartGuard.OnFailure.DISCARD, StartError.START_FAILED) { it.writer.open() }
        assertEquals("ok", result.runId)
        assertNull(result.error)
        assertEquals(s, pending)
        assertEquals(1, launched)
    }
}
