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
 * The guard's plumbing: on a throw the session is unregistered, `abortStart` runs, the error
 * is `resumeFailed` for a resumed session and the given one otherwise; the journal fate is
 * the session's decision (see [app.runsolo.record.RecordingSessionAbortTest] for the real class).
 */
class StartGuardTest {
    // A real temp directory: the in-memory fake lives in core-jvm's test sources, not its jar.
    private val fs = JvmFileSystem(Files.createTempDirectory("runsolo-startguard"))

    private inner class FakeSession(override val runId: String, override val resumed: Boolean) : StartGuard.Session {
        val writer = JournalWriter(fs, runId)
        var aborted = 0

        init {
            fs.mkdirs(RunPaths.RUNS_DIR)
            if (resumed) {
                fs.mkdirs(RunPaths.journalDir(runId))
                fs.openAppend(RunPaths.journal(runId)).use { a ->
                    a.write((JournalCodec.encode(JournalLine.Header(0, 1_700_000_000_000L, runId, "d", "a", "UTC", RunMode.free, null, Units.km)) + "\n").toByteArray())
                }
            }
        }

        // What RecordingSession.abortStart does to the journal: keep a resumed one, delete a new one.
        override fun abortStart() {
            aborted++
            writer.close()
            if (!resumed) fs.deleteRecursively(RunPaths.journalDir(runId))
        }
    }

    private var pending: FakeSession? = null
    private var launched = 0

    private fun run(session: FakeSession, step: (FakeSession) -> Unit): StartResult =
        StartGuard.begin(
            session = session,
            register = { pending = it },
            startStep = step,
            launch = { launched++; StartResult(runId = it.runId, error = null) },
        )

    @Test
    fun `resume start step throws - journal kept, pending cleared, recover lists it, resumeFailed`() {
        val s = FakeSession("r1", resumed = true)
        val result = run(s) {
            it.writer.open()
            throw IllegalStateException("boom while resuming")
        }
        assertNull(result.runId)
        assertEquals(StartError.RESUME_FAILED, result.error)
        assertNull(pending)
        assertEquals(0, launched)
        assertEquals(1, s.aborted)
        assertTrue("journal must survive a failed resume", fs.exists(RunPaths.journal("r1")))
        val orphans = Reconciler(fs).orphans(1_700_000_100_000L, activeRunId = null)
        assertEquals(listOf("r1"), orphans.map { it.runId })
        assertTrue(orphans.single().readable)
    }

    @Test
    fun `new run start step throws - journal discarded, pending cleared, startFailed`() {
        val s = FakeSession("n1", resumed = false)
        val result = run(s) {
            it.writer.open()
            throw java.io.IOException("ENOSPC")
        }
        assertEquals(StartError.START_FAILED, result.error)
        assertNull(pending)
        assertEquals(1, s.aborted)
        assertFalse(fs.exists(RunPaths.journalDir("n1")))
        assertTrue(Reconciler(fs).orphans(0, activeRunId = null).isEmpty())
    }

    @Test
    fun `failureError - resumed sessions report resumeFailed whatever the path`() {
        val resumed = FakeSession("r2", resumed = true)
        val fresh = FakeSession("n2", resumed = false)
        assertEquals(StartError.RESUME_FAILED, StartGuard.failureError(resumed, StartError.FGS_NOT_ALLOWED))
        assertEquals(StartError.FGS_NOT_ALLOWED, StartGuard.failureError(fresh, StartError.FGS_NOT_ALLOWED))
    }

    @Test
    fun `start step succeeds - session stays registered and is launched`() {
        val s = FakeSession("ok", resumed = false)
        val result = run(s) { it.writer.open() }
        assertEquals("ok", result.runId)
        assertNull(result.error)
        assertEquals(s, pending)
        assertEquals(1, launched)
    }
}
