package app.runsolo.record

import android.content.Context
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.annotation.Config

/** The km check-in's tail rides the km utterance only when the speech queued ahead lets it start on time (3 s rule). */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34])
class CuePlayerTailTest {
    private val context: Context = RuntimeEnvironment.getApplication()
    private var clock = 0L

    @Test
    fun `tail is said after the km line when nothing is queued ahead`() {
        val cues = CuePlayer(context) { clock }
        val said = cues.play(null, "3 k, 15 minutes 20, pace 5:07.", null, tail = "Zone 2 for 12 minutes.")
        assertEquals("3 k, 15 minutes 20, pace 5:07. Zone 2 for 12 minutes.", said?.text)
    }

    @Test
    fun `tail is dropped when queued speech would start it more than 3 s late`() {
        val cues = CuePlayer(context) { clock }
        // 16 words queued: about 6 s of speech ahead, so the tail could not start in time.
        cues.announce("one two three four five six seven eight nine ten eleven twelve thirteen fourteen fifteen sixteen")
        val said = cues.play(null, "4 k, 20 minutes, pace 5:00.", null, tail = "Zone 2 for 12 minutes.")
        assertNotNull(said)
        assertEquals("4 k, 20 minutes, pace 5:00.", said?.text)
    }

    @Test
    fun `tail is said again once the queue has cleared`() {
        val cues = CuePlayer(context) { clock }
        cues.announce("one two three four five six seven eight nine ten eleven twelve thirteen fourteen fifteen sixteen")
        clock = 6_000
        val said = cues.play(null, "4 k, 20 minutes, pace 5:00.", null, tail = "Zone 2.")
        assertEquals("4 k, 20 minutes, pace 5:00. Zone 2.", said?.text)
    }
}
