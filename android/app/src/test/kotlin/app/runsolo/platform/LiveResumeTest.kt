package app.runsolo.platform

import android.content.Context
import app.runsolo.core.fs.JvmFileSystem
import app.runsolo.core.journal.JournalCodec
import app.runsolo.core.journal.JournalLine
import app.runsolo.core.journal.JournalReplay
import app.runsolo.core.model.LiveBoard
import app.runsolo.core.model.LiveBoardKind
import app.runsolo.core.model.LiveContext
import app.runsolo.core.model.LiveEntry
import app.runsolo.core.model.RunMode
import app.runsolo.core.model.Units
import app.runsolo.core.run.RunPaths
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.annotation.Config
import kotlin.math.cos

/**
 * BLOCK-1 through the real resume path (#37 review P3): `resumeRecovered`'s session carries the
 * journaled `lctx`, and `startResumed` rebuilds the coach with the journaled `cf` lines and the
 * distance run so far, so a compare already said stays said and a passed km is dropped.
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34])
class LiveResumeTest {
    private val context: Context = RuntimeEnvironment.getApplication()
    private val fs = JvmFileSystem(context.filesDir.toPath())
    private val w0 = 1_700_000_000_000L

    private val ctx = LiveContext(
        boards = listOf(
            LiveBoard(
                key = "be:5k", label = "5K", kind = LiveBoardKind.distance, targetM = 5_000.0,
                entries = listOf(800_000L, 900_000L, 1_000_000L).mapIndexed { i, k3 ->
                    LiveEntry("r$i", 0, fromStartSplitsMs = List(5) { k -> k3 * (k + 1) / 3 }, finalMetric = k3 * 5 / 3.0)
                },
            ),
        ),
        builtAtMs = w0, engineVersion = 1,
    )

    /** A Free run killed at 2.5 km (3.5 m/s east), with compares journaled for km 1 and 2. */
    private fun writeOrphan(id: String, muted: Boolean = false) {
        fs.mkdirs(RunPaths.journalDir(id))
        val lat0 = -33.8688
        val lon0 = 151.2093
        val mPerDegLon = 111_320.0 * cos(Math.toRadians(lat0))
        val lines = ArrayList<JournalLine>()
        lines.add(JournalLine.Header(0, w0, id, "d", "a", "UTC", RunMode.free, null, Units.km))
        lines.add(JournalLine.LiveContextLine(0, w0, ctx))
        for (s in 1..714) {
            val t = s * 1_000L
            lines.add(JournalLine.Sample(t, w0 + t, lat0, lon0 + 3.5 * s / mPerDegLon, null, 5.0, 3.5, 150))
            if (s == 286 || s == 572) lines.add(JournalLine.CueFired(t, w0 + t, JournalLine.FiredKind.compare, "be:5k", s / 286, t))
            if (muted && s == 600) lines.add(JournalLine.TipsMuted(t, w0 + t))
        }
        fs.openAppend(RunPaths.journal(id)).use { a -> for (l in lines) a.write((JournalCodec.encode(l) + "\n").toByteArray()) }
    }

    @Test
    fun `resumeRecovered keeps the journaled context and fired compares`() {
        writeOrphan("live-1")
        val replayed = JournalReplay.read(fs.readBytes(RunPaths.journal("live-1")))
        assertEquals(ctx, replayed.liveContext)
        val session = RecorderApiImpl(context).resumeSession("live-1", replayed)
        session.startResumed(replayed)
        val coach = session.liveCoach
        assertTrue("the restored coach has the journaled board", coach.active)
        // km 2 passed before the kill: nothing, not even the split, is said late.
        assertNull(coach.onTick(0, 1_999.0, 1_000, 2_001.0) { 600_000 })
        // km 3 after the resume: the split and the compare against the journaled board.
        val k3 = coach.onTick(0, 2_999.0, 1_000, 3_001.0) { 880_000 }
        assertNotNull(k3?.fire)
        assertEquals(listOf(2, 4), listOf(k3!!.fire!!.result.rank, k3.fire!!.result.of))
        session.abortStart()
    }

    @Test
    fun `a journaled Mute tips stays muted after the kill`() {
        writeOrphan("live-2", muted = true)
        val replayed = JournalReplay.read(fs.readBytes(RunPaths.journal("live-2")))
        assertTrue(replayed.tipsMuted)
        val session = RecorderApiImpl(context).resumeSession("live-2", replayed)
        session.startResumed(replayed)
        val coach = session.liveCoach
        assertTrue("still muted after the restore", coach.muted)
        // The km 3 compare still fires for the journal and the app, but is not spoken.
        val k3 = coach.onTick(0, 2_999.0, 1_000, 3_001.0) { 880_000 }
        assertEquals(false, k3?.fire?.speak)
        assertEquals(true, session.status().tipsMuted)
        session.abortStart()
    }
}
