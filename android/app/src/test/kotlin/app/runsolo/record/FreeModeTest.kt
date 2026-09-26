package app.runsolo.record

import android.content.Context
import app.runsolo.core.model.Phase
import app.runsolo.core.model.RecorderState
import app.runsolo.core.model.RunMode
import app.runsolo.core.model.Units
import app.runsolo.core.fs.JvmFileSystem
import app.runsolo.core.journal.JournalReplay
import app.runsolo.core.journal.RunEvent
import app.runsolo.core.model.LapSource
import app.runsolo.core.run.RunPaths
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.annotation.Config

/** Plan §18.2: Free mode has no LAP anywhere — notification action, volume keys, API — while Laps keeps them. */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34])
class FreeModeTest {
    private val context: Context = RuntimeEnvironment.getApplication()
    private val fs = JvmFileSystem(context.filesDir.toPath())

    private fun content(mode: RunMode, lapAction: Boolean) = RecorderNotification.Content(
        state = RecorderState.recording, phase = Phase.none, repIndex = 0, reps = null,
        elapsedBaseRealtime = 0, phaseRemainingMs = null, lapIndex = 0, hr = 150, lapAction = lapAction,
    )

    @Test
    fun `notification has no LAP action in free mode and keeps Pause and Stop`() {
        val n = RecorderNotification(context).also { it.createChannel() }
        val free = n.build(content(RunMode.free, lapAction = false))
        assertEquals(listOf("Pause", "Stop"), free.actions.map { it.title.toString() })
        val laps = n.build(content(RunMode.laps, lapAction = true))
        assertEquals(listOf("LAP", "Pause", "Stop"), laps.actions.map { it.title.toString() })
    }

    @Test
    fun `session in free mode - lap from every source is a no-op, journal has no lap line, notification content has no LAP`() {
        fs.mkdirs(RunPaths.RUNS_DIR)
        val s = RecordingSession(context, "free-1", RunMode.free, null, Units.km, null, volumeKeyLaps = true)
        s.startNew(device = "t", app = "t", tz = "UTC")
        for (src in LapSource.values()) s.lap(src)
        assertEquals(0, s.status().laps.size)
        assertFalse(s.notificationContent().lapAction)
        val path = s.stop()
        assertTrue(path != null)
        val m = app.runsolo.core.run.RunFile.readJson(fs.readBytes(path!!))
        assertEquals("free", m["mode"])
        assertEquals(3L, m["schema"])
        assertEquals(1, (m["laps"] as List<*>).size)
    }

    @Test
    fun `session in laps mode - manual laps land, journal carries them, notification content has LAP`() {
        fs.mkdirs(RunPaths.RUNS_DIR)
        val s = RecordingSession(context, "laps-1", RunMode.laps, null, Units.km, null, volumeKeyLaps = true)
        s.startNew(device = "t", app = "t", tz = "UTC")
        assertTrue(s.notificationContent().lapAction)
        s.lap(LapSource.button)
        org.robolectric.shadows.ShadowSystemClock.advanceBy(java.time.Duration.ofMillis(1_600)) // a Laps run ignores a re-press within 1.5 s of device time
        s.lap(LapSource.volumeKey)
        val replay = JournalReplay.read(fs.readBytes(RunPaths.journal("laps-1")))
        assertEquals(RunMode.laps, replay.header.mode)
        assertEquals(listOf(LapSource.button, LapSource.volumeKey), replay.events.filterIsInstance<RunEvent.Lap>().map { it.source })
        // Manual laps reach the status at the next tick (distance interpolated at the press); stop flushes them.
        assertTrue(s.stop() != null)
        assertEquals(2, s.status().laps.size)
    }
}
