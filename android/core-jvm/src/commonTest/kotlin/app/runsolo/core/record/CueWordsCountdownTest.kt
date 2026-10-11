package app.runsolo.core.record

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull

class CueWordsCountdownTest {
    @Test
    fun `beats say three two one go`() {
        assertEquals(listOf("Three", "Two", "One", "Go"), listOf(3, 2, 1, 0).map { CueWords.countdownBeat(it) })
    }

    @Test
    fun `other numbers say nothing`() {
        assertNull(CueWords.countdownBeat(4))
        assertNull(CueWords.countdownBeat(10))
        assertNull(CueWords.countdownBeat(-1))
    }
}
