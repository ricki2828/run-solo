package app.runsolo.core.live

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull

/** The nudge's own line (founder 26-Sep): 2 s after the cue is done, within 6 s of it, never behind other speech. */
class NudgeFollowUpTest {
    private val n = LiveCoach.Nudge("fast_start", 1, "Easy start. Your best 5K went out slower than this.")

    @Test
    fun `said at the first tick 2 s after the cue is done, once`() {
        val f = NudgeFollowUp().also { it.offer(n, cueDoneAt = 10_000) }
        assertNull(f.due(11_999, 10_000), "the pause first")
        assertEquals(n, f.due(12_000, 10_000))
        assertNull(f.due(13_000, 10_000), "once")
    }

    @Test
    fun `dropped past the 6 s window, while something is still speaking, or when another cue came first`() {
        assertNull(NudgeFollowUp().also { it.offer(n, 10_000) }.due(16_001, 10_000), "a stalled tick: too late")
        assertEquals(n, NudgeFollowUp().also { it.offer(n, 10_000) }.due(16_000, 10_000), "the window's last ms")
        val busy = NudgeFollowUp().also { it.offer(n, 10_000) }
        assertNull(busy.due(12_000, 14_000), "never queued behind other speech")
        assertNull(busy.due(15_000, 14_000), "and not tried again later")
        val other = NudgeFollowUp().also { it.offer(n, 10_000) }
        other.cancel()
        assertNull(other.due(12_000, 10_000))
    }
}
