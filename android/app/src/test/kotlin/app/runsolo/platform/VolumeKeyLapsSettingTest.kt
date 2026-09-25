package app.runsolo.platform

import android.content.Context
import app.runsolo.core.model.RunMode
import app.runsolo.core.model.Units
import app.runsolo.record.RecorderService
import app.runsolo.record.RecordingSession
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.annotation.Config

/** `setVolumeKeyLaps` persists, a later RecorderApiImpl (next run / process) reads it, and it reaches LapInput. */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35]) // volume-key laps are supported here (not 34)
class VolumeKeyLapsSettingTest {
    private val context: Context = RuntimeEnvironment.getApplication()

    @Before
    fun clearPrefs() {
        context.getSharedPreferences(RecorderService.PREFS, Context.MODE_PRIVATE).edit().clear().commit()
    }

    private fun session(id: String, mode: RunMode, api: RecorderApiImpl) =
        RecordingSession(context, id, mode, null, Units.km, null, api.volumeKeyLaps(mode))

    @Test
    fun `unset - mode default - on for laps, off for free`() {
        val api = RecorderApiImpl(context)
        assertTrue(api.volumeKeyLaps(RunMode.laps))
        assertFalse(api.volumeKeyLaps(RunMode.free))
    }

    @Test
    fun `off - survives to the next run and LapInput is never registered`() {
        RecorderApiImpl(context).setVolumeKeyLaps(false)
        val next = RecorderApiImpl(context)
        assertFalse(next.volumeKeyLaps(RunMode.laps))
        val s = session("vk-off", RunMode.laps, next)
        s.enableLapInput()
        assertFalse(s.lapInput.registered)
    }

    @Test
    fun `on - survives to the next run and LapInput is registered`() {
        RecorderApiImpl(context).setVolumeKeyLaps(false)
        RecorderApiImpl(context).setVolumeKeyLaps(true)
        val next = RecorderApiImpl(context)
        assertTrue(next.volumeKeyLaps(RunMode.laps))
        val s = session("vk-on", RunMode.laps, next)
        s.enableLapInput()
        assertTrue(s.lapInput.registered)
        s.lapInput.disable()
    }

    @Test
    fun `on never enables volume-key laps in free mode`() {
        RecorderApiImpl(context).setVolumeKeyLaps(true)
        val s = session("vk-free", RunMode.free, RecorderApiImpl(context))
        s.enableLapInput()
        assertFalse(s.lapInput.registered)
    }
}
