package app.runsolo.record

import android.content.Context
import org.junit.Assert.assertFalse
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.annotation.Config

/** The Ready countdown's line is dropped, not toned, when TTS is not ready or cues are off. */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34])
class CuePlayerCountdownTest {
    private val context: Context = RuntimeEnvironment.getApplication()

    @Test
    fun `speakIfReady drops the line before init`() {
        val cues = CuePlayer(context)
        assertFalse(cues.speakIfReady("Three"))
    }

    @Test
    fun `speakIfReady drops the line when TTS never became ready`() {
        val cues = CuePlayer(context)
        cues.init()
        assertFalse(cues.speakIfReady("Three"))
        cues.release()
    }

    @Test
    fun `speakIfReady drops the line when cues are off`() {
        val cues = CuePlayer(context)
        cues.enabled = false
        assertFalse(cues.speakIfReady("Go"))
    }
}
