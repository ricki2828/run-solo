package app.runsolo.record

import android.content.Context
import android.content.Intent
import android.media.AudioManager
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config
import org.robolectric.shadows.ShadowSystemClock
import java.time.Duration

/**
 * The Android-14 stream-change fallback (PR #9 review): only API 34, only STREAM_MUSIC, only a
 * single step, only while no music is active, not right after an audio-device change; the
 * volume is restored; every other API stays on the MediaSession path alone.
 */
@RunWith(RobolectricTestRunner::class)
class LapInputTest {
    private val context: Context = RuntimeEnvironment.getApplication()
    private val audio = context.getSystemService(Context.AUDIO_SERVICE) as AudioManager
    private var laps = 0
    private var unavailable = 0

    private fun input(fallback: Boolean) = LapInput(context, onLap = { laps++ }, onUnavailable = { unavailable++ }, streamFallback = fallback)

    private fun volumeChanged(stream: Int, prev: Int, value: Int) {
        audio.setStreamVolume(stream, value, 0)
        context.sendBroadcast(
            Intent(LapInput.VOLUME_CHANGED_ACTION)
                .putExtra(LapInput.EXTRA_STREAM_TYPE, stream)
                .putExtra(LapInput.EXTRA_STREAM_VALUE, value)
                .putExtra(LapInput.EXTRA_PREV_STREAM_VALUE, prev),
        )
        shadowOf(android.os.Looper.getMainLooper()).idle()
    }

    private fun advance(ms: Long) = ShadowSystemClock.advanceBy(Duration.ofMillis(ms))

    @Test
    @Config(sdk = [34])
    fun `API 34 - one-step music change laps once, restores the volume, debounced`() {
        val li = input(fallback = true)
        li.enable()
        advance(1_000) // Robolectric's elapsedRealtime starts near 0; the debounce must not eat the first press
        audio.setStreamVolume(AudioManager.STREAM_MUSIC, 7, 0)
        volumeChanged(AudioManager.STREAM_MUSIC, prev = 7, value = 8)
        assertEquals("first one-step press must lap (laps=$laps lastPath=${li.lastPath} music=${audio.isMusicActive} vol=${audio.getStreamVolume(AudioManager.STREAM_MUSIC)})", 1, laps)
        assertEquals("stream", li.lastPath)
        assertEquals("volume restored", 7, audio.getStreamVolume(AudioManager.STREAM_MUSIC))
        // The restore's own broadcast (8→7 within the suppress window) is not a press.
        volumeChanged(AudioManager.STREAM_MUSIC, prev = 8, value = 7)
        assertEquals(1, laps)
        advance(1_000)
        volumeChanged(AudioManager.STREAM_MUSIC, prev = 7, value = 6)
        assertEquals(2, laps)
        assertEquals(0, unavailable)
        li.disable()
    }

    @Test
    @Config(sdk = [34])
    fun `API 34 - other streams, multi-step changes and device changes are not presses`() {
        val li = input(fallback = true)
        li.enable()
        volumeChanged(AudioManager.STREAM_RING, prev = 3, value = 4)
        assertEquals(0, laps)
        volumeChanged(AudioManager.STREAM_MUSIC, prev = 3, value = 6) // adb `media volume --set`
        assertEquals(0, laps)
        context.sendBroadcast(Intent(AudioManager.ACTION_AUDIO_BECOMING_NOISY))
        shadowOf(android.os.Looper.getMainLooper()).idle()
        advance(500)
        volumeChanged(AudioManager.STREAM_MUSIC, prev = 6, value = 7) // headset just came out
        assertEquals("change within the device-change quiet window must not lap (laps=$laps)", 0, laps)
        advance(LapInput.DEVICE_CHANGE_QUIET_MS)
        volumeChanged(AudioManager.STREAM_MUSIC, prev = 7, value = 8)
        assertEquals(1, laps)
        li.disable()
    }

    @Test
    @Config(sdk = [34])
    fun `API 34 - music active - fallback off and unavailable reported once`() {
        shadowOf(audio).setIsMusicActive(true)
        val li = input(fallback = true)
        li.enable()
        assertEquals(1, unavailable)
        volumeChanged(AudioManager.STREAM_MUSIC, prev = 5, value = 6)
        assertEquals(0, laps)
        assertEquals(1, unavailable)
        assertEquals("not restored: it was the user's volume", 6, audio.getStreamVolume(AudioManager.STREAM_MUSIC))
        li.disable()
    }

    @Test
    @Config(sdk = [35]) // highest SDK Robolectric 4.14 ships; the gate is `== 34`, so 35 behaves like 36
    fun `API 35 (default gating) - no stream fallback at all`() {
        val li = LapInput(context, onLap = { laps++ }, onUnavailable = { unavailable++ })
        li.enable()
        volumeChanged(AudioManager.STREAM_MUSIC, prev = 5, value = 6)
        assertEquals(0, laps)
        assertEquals(0, unavailable)
        assertTrue(li.lastPath == null)
        li.disable()
    }

    @Test
    @Config(sdk = [34])
    fun `disable unregisters - a change after disable is ignored`() {
        val li = input(fallback = true)
        li.enable()
        li.disable()
        volumeChanged(AudioManager.STREAM_MUSIC, prev = 5, value = 6)
        assertEquals(0, laps)
        assertFalse(li.lastPath == "stream")
    }
}
