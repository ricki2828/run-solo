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

    @Test
    fun `a flush clears the queue so the next line starts now and only a briefing in flight is interrupted`() {
        val c = SpeechClock()
        c.queued(0, 28) // the start briefing, 10.5 s
        assertTrue(SpeechClock.interrupts(c.busyUntil, 5_000L))
        assertFalse(SpeechClock.interrupts(c.busyUntil, 11_000L), "already finished")
        assertFalse(SpeechClock.interrupts(0L, 5_000L), "no briefing in flight")
        c.interrupt(5_000L)
        assertTrue(c.freshAt(5_000L))
        c.queued(5_000L, 6) // Go. Rep 1 of 4
        assertTrue(c.busyUntil == 5_000L + 6 * SpeechClock.MS_PER_WORD)
    }
}
