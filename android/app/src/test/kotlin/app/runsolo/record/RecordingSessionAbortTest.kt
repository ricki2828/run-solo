package app.runsolo.record

import android.content.Context
import app.runsolo.core.fs.JvmFileSystem
import app.runsolo.core.journal.JournalCodec
import app.runsolo.core.journal.JournalLine
import app.runsolo.core.journal.JournalReplay
import app.runsolo.core.model.LapSource
import app.runsolo.core.model.Preset
import app.runsolo.core.model.RunMode
import app.runsolo.core.model.Units
import app.runsolo.core.reconcile.Reconciler
import app.runsolo.core.run.RunPaths
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.annotation.Config

/**
 * The real [RecordingSession] under Robolectric: every pre-recording failure path
 * (`StartGuard` start step, `startForegroundService` in `RecorderApiImpl.launch`,
 * `startForeground` in `RecorderService.startRun`) ends in [RecordingSession.abortStart], so
 * this pins what that does to the journal for a resumed and for a brand-new session.
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34])
class RecordingSessionAbortTest {
    private val context: Context = RuntimeEnvironment.getApplication()
    private val fs = JvmFileSystem(context.filesDir.toPath())
    private val w0 = 1_700_000_000_000L

    private fun writeOrphan(id: String, preset: Preset? = Preset.DEFAULT_4X4) {
        fs.mkdirs(RunPaths.journalDir(id))
        val lines = listOf(
            JournalLine.Header(1_000, w0, id, "d", "a", "UTC", RunMode.fourByFour, preset, Units.km),
            JournalLine.Lap(61_000, w0 + 60_000, LapSource.button),
            JournalLine.Sample(62_000, w0 + 61_000, -33.8, 151.2, null, 5.0, 3.0, 150),
        )
        fs.openAppend(RunPaths.journal(id)).use { a -> for (l in lines) a.write((JournalCodec.encode(l) + "\n").toByteArray()) }
    }

    @Test
    fun `abortStart on a resumed session keeps the journal - recover lists it, content intact plus the gap line`() {
        writeOrphan("orphan-1")
        val orphan = JournalReplay.read(fs.readBytes(RunPaths.journal("orphan-1")))
        val session = RecordingSession(context, "orphan-1", RunMode.fourByFour, Preset.DEFAULT_4X4, Units.km, null, volumeKeyLaps = false)
        session.startResumed(orphan)
        assertTrue(session.resumed)

        session.abortStart() // what every failed launch / startForeground path calls

        assertTrue("journal must survive an aborted resume", fs.exists(RunPaths.journal("orphan-1")))
        val orphans = Reconciler(fs).orphans(w0 + 120_000, activeRunId = null)
        assertEquals(listOf("orphan-1"), orphans.map { it.runId })
        assertTrue(orphans.single().readable)
        val replay = JournalReplay.read(fs.readBytes(RunPaths.journal("orphan-1")))
        assertEquals(1, replay.events.count { it is app.runsolo.core.journal.RunEvent.Lap })
        assertEquals(1, replay.events.count { it is app.runsolo.core.journal.RunEvent.Gap })
        assertFalse("no run file may appear: abort never finalises", fs.exists(RunPaths.runFile("orphan-1")))
    }

    @Test
    fun `startResumed that throws (restore fails) - resumed is already set, so abortStart keeps the journal (PR5 P3)`() {
        // A 4x4 header without a preset makes RecorderCore.restore throw after the gap line was written.
        writeOrphan("orphan-2", preset = null)
        val orphan = JournalReplay.read(fs.readBytes(RunPaths.journal("orphan-2")))
        val session = RecordingSession(context, "orphan-2", RunMode.fourByFour, null, Units.km, null, volumeKeyLaps = false)
        val thrown = try {
            session.startResumed(orphan)
            null
        } catch (e: Exception) {
            e
        }
        assertTrue("restore must throw for this fixture", thrown != null)
        assertTrue("resumed is set before open/restore", session.resumed)

        session.abortStart() // what StartGuard.begin does on the throw

        assertTrue(fs.exists(RunPaths.journal("orphan-2")))
        val orphans = Reconciler(fs).orphans(w0 + 120_000, activeRunId = null)
        assertEquals(listOf("orphan-2"), orphans.map { it.runId })
        assertTrue(orphans.single().readable)
        assertFalse(fs.exists(RunPaths.runFile("orphan-2")))
    }

    @Test
    fun `abortStart on a brand-new session discards its header-only journal`() {
        fs.mkdirs(RunPaths.RUNS_DIR)
        val session = RecordingSession(context, "new-1", RunMode.free, null, Units.km, null, volumeKeyLaps = true)
        session.startNew(device = "test", app = "test", tz = "UTC")
        assertFalse(session.resumed)
        assertTrue(fs.exists(RunPaths.journal("new-1")))

        session.abortStart()

        assertFalse(fs.exists(RunPaths.journalDir("new-1")))
        assertFalse(fs.exists(RunPaths.runFile("new-1")))
        assertTrue(Reconciler(fs).orphans(w0, activeRunId = null).isEmpty())
    }
}
