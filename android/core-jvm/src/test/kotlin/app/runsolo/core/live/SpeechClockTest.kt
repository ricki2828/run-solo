package app.runsolo.core.live

import kotlin.test.Test
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class SpeechClockTest {
    @Test
    fun `an extra is dropped when the queue ahead of it would make it more than 3 s late`() {
        val c = SpeechClock()
        assertTrue(c.freshAt(0))
        c.queued(0, 16) // about 6 s of speech
        assertFalse(c.freshAt(1_000), "5 s of speech still ahead")
        assertTrue(c.freshAt(3_000), "3 s ahead: just in time")
        c.queued(10_000, 4) // the queue had drained; starts now
        assertTrue(c.freshAt(10_500))
    }
}
