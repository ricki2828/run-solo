package app.runsolo.record

import android.content.Context
import android.media.AudioManager
import android.os.Looper
import android.view.KeyEvent
import app.runsolo.core.live.HeadsetKeys
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config
import java.time.Duration

/**
 * Android 14 (PR #9): volume keys never reach an app's remote session, so no session is
 * registered there and "unavailable" is reported once; every other API registers the session.
 */
@RunWith(RobolectricTestRunner::class)
class LapInputTest {
    private val context: Context = RuntimeEnvironment.getApplication()
    private var laps = 0
    private var unavailable = 0

    private val answers = mutableListOf<Int>()

    private fun input() = LapInput(context, onLap = { laps++ }, onUnavailable = { unavailable++ })

    /** With a prompt receiver, as RecordingSession builds it (volume-key laps on or off is [LapInput.enable]). */
    private fun promptInput() = LapInput(context, onLap = { laps++ }, onPromptPress = { answers += it })

    private fun down(code: Int) = KeyEvent(KeyEvent.ACTION_DOWN, code)

    private fun up(code: Int) = KeyEvent(KeyEvent.ACTION_UP, code)

    /** Past the grace after a prompt closes (the main looper runs the prompt-only session's release too). */
    private fun pastGrace() = shadowOf(Looper.getMainLooper()).idleFor(Duration.ofMillis(LapInput.GRACE_MS + 100))

    @Test
    @Config(sdk = [34])
    fun `API 34 - volume-key laps not supported`() {
        assertFalse(LapInput.SUPPORTED)
    }

    @Test
    @Config(sdk = [29, 35])
    fun `API 29 and 35 - volume-key laps supported`() {
        assertTrue(LapInput.SUPPORTED)
    }

    @Test
    @Config(sdk = [34])
    fun `API 34 - no session, unavailable reported once per run`() {
        val li = input()
        li.enable()
        assertFalse(li.registered)
        assertEquals(1, unavailable)
        li.disable()
        li.enable() // sensors re-attached within the same run
        assertEquals(1, unavailable)
        assertEquals(0, laps)
    }

    @Test
    @Config(sdk = [29])
    fun `API 29 - session registered, nothing reported`() {
        val li = input()
        li.enable()
        assertTrue(li.registered)
        assertEquals(0, unavailable)
        li.disable()
        assertFalse(li.registered)
    }

    @Test
    @Config(sdk = [35]) // highest SDK Robolectric 4.14 ships; the gate is `!= 34`, so 35 behaves like 36
    fun `API 35 - session registered, nothing reported`() {
        val li = input()
        li.enable()
        assertTrue(li.registered)
        assertEquals(0, unavailable)
        li.disable()
    }

    // ---- coach prompts (#384 follow-up) ----

    @Test
    @Config(sdk = [35])
    fun `headset keys answer an open prompt - play-pause and the hook count and NEXT and PREVIOUS pick`() {
        val li = promptInput()
        li.holdForPrompt(true)
        assertTrue(li.mediaKey(down(KeyEvent.KEYCODE_HEADSETHOOK)))
        assertTrue(li.mediaKey(down(KeyEvent.KEYCODE_MEDIA_PLAY_PAUSE)))
        assertTrue(li.mediaKey(down(KeyEvent.KEYCODE_MEDIA_NEXT)))
        assertTrue(li.mediaKey(down(KeyEvent.KEYCODE_MEDIA_PREVIOUS)))
        assertEquals(listOf(HeadsetKeys.COUNT, HeadsetKeys.COUNT, 1, 0), answers)
        // The key up is taken too (never reaches the music app) but is not a second press.
        assertTrue(li.mediaKey(up(KeyEvent.KEYCODE_MEDIA_NEXT)))
        assertEquals(4, answers.size)
        // A key the prompt does not use is the music app's.
        assertFalse(li.mediaKey(down(KeyEvent.KEYCODE_MEDIA_STOP)))
        assertEquals(0, laps)
        li.disable()
    }

    @Test
    @Config(sdk = [35])
    fun `headset keys go to the music app when no prompt is open - and are swallowed in the grace after one`() {
        val li = promptInput()
        assertFalse(li.mediaKey(down(KeyEvent.KEYCODE_MEDIA_PLAY_PAUSE)))
        li.holdForPrompt(true)
        li.holdForPrompt(false)
        assertTrue(li.mediaKey(down(KeyEvent.KEYCODE_MEDIA_NEXT)))
        assertTrue(answers.isEmpty())
        pastGrace()
        assertFalse(li.mediaKey(down(KeyEvent.KEYCODE_MEDIA_NEXT)))
        assertTrue(answers.isEmpty())
        li.disable()
    }

    @Test
    @Config(sdk = [35])
    fun `with no volume-key laps the prompt makes its own session and volume keys answer it`() {
        val li = promptInput()
        assertFalse(li.registered)
        li.holdForPrompt(true)
        assertTrue(li.registered)
        li.volumeKey(AudioManager.ADJUST_LOWER)
        assertEquals(listOf(HeadsetKeys.COUNT), answers)
        assertEquals(0, laps)
        li.holdForPrompt(false)
        li.volumeKey(AudioManager.ADJUST_LOWER) // the tail of a double press: ignored and never a lap
        assertEquals(1, answers.size)
        assertEquals(0, laps)
        pastGrace()
        assertFalse(li.registered) // released: the music app gets its buttons back
    }

    @Test
    @Config(sdk = [35])
    fun `with volume-key laps on a volume press mid-prompt is still the lap and the headset still answers`() {
        val li = promptInput()
        li.enable()
        li.holdForPrompt(true)
        li.volumeKey(AudioManager.ADJUST_RAISE)
        assertEquals(1, laps)
        assertTrue(answers.isEmpty())
        assertTrue(li.mediaKey(down(KeyEvent.KEYCODE_MEDIA_PLAY_PAUSE)))
        assertEquals(listOf(HeadsetKeys.COUNT), answers)
        li.holdForPrompt(false)
        pastGrace()
        li.volumeKey(AudioManager.ADJUST_RAISE)
        assertEquals(2, laps)
        assertTrue(li.registered) // the lap session stays for the run
        li.disable()
    }

    @Test
    @Config(sdk = [35])
    fun `a volume press right after a prompt closes is still a lap where volume-key laps are on`() {
        val li = promptInput()
        li.enable()
        li.holdForPrompt(true)
        li.holdForPrompt(false)
        li.volumeKey(AudioManager.ADJUST_LOWER)
        assertEquals(1, laps)
        li.disable()
    }
}
