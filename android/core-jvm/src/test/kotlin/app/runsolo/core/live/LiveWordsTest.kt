package app.runsolo.core.live

import app.runsolo.core.model.CueKind
import app.runsolo.core.model.CueProfile
import app.runsolo.core.model.Phase
import app.runsolo.core.model.SessionSpec
import app.runsolo.core.record.CueWords
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

/** WARN-2: every compare, with the longest numbers, fits the cue it rides on in 16 words; no em dashes. */
class LiveWordsTest {
    private fun r(kind: CompareKind, rank: Int, of: Int, index: Int = 40, label: String = "10K", deltaMs: Long? = null, deltaSec: Double? = null, deltaVo2: Double? = null, value: Double? = null) =
        CompareResult("k", label, kind, index, rank, of, deltaMs, deltaSec, deltaVo2, value)

    /** The longest base cue each kind can ride on. */
    private val longestBase = mapOf(
        CompareKind.distance to LiveWords.kmSplit(10, 7_199_000, 599_000),
        CompareKind.intervals to CueWords.text(CueKind.phaseEnd, null, SessionSpec.norwegian4x4(), Phase.cooldown, 4, null)!!,
        CompareKind.cooper to CooperProjection.cue(11, 9_999.0),
        CompareKind.target to CueWords.text(CueKind.projection, 7_199_000.0, SessionSpec.norwegian4x4().copy(cueProfile = CueProfile.standard), Phase.work, 1, 0, 9)!!,
    )

    private val longest = listOf(
        r(CompareKind.distance, 20, 21, deltaMs = 999_000), r(CompareKind.distance, 1, 21, deltaMs = -999_000), r(CompareKind.distance, 1, 2, deltaMs = 999_000),
        r(CompareKind.intervals, 20, 21, deltaSec = 9.0), r(CompareKind.intervals, 1, 21, deltaSec = -9.0), r(CompareKind.intervals, 1, 2, deltaSec = 9.0),
        r(CompareKind.cooper, 20, 21, deltaVo2 = -30.0), r(CompareKind.cooper, 1, 2, deltaVo2 = -30.0), r(CompareKind.cooper, 2, 21, deltaVo2 = -1.0),
        r(CompareKind.target, 1, 1, label = "predicted", deltaMs = 999_000, value = 7_199_000.0),
    )

    @Test
    fun `every compare template fits its longest cue in 16 words`() {
        for (c in longest) {
            val base = longestBase.getValue(c.kind)
            val composed = CueComposer.compose(base, LiveWords.compare(c))
            assertTrue(composed.compareSpoken, "dropped: $base + ${LiveWords.compare(c)}")
            assertTrue(CueComposer.words(composed.text) <= CueComposer.MAX_WORDS, "${CueComposer.words(composed.text)} words: ${composed.text}")
            assertFalse(composed.text!!.contains('—'), composed.text!!)
        }
        assertEquals(7, CueComposer.words(LiveWords.kmSplit(10, 7_199_000, 599_000)), "the longest km split")
    }

    @Test
    fun `the plan's copy`() {
        assertEquals(
            "3 k, 15 minutes 20, pace 5:07. Number 2 of 7, 6 seconds off your best.",
            CueComposer.compose(LiveWords.kmSplit(3, 920_000, 307_000), LiveWords.compare(r(CompareKind.distance, 2, 7, label = "5K", deltaMs = 6_000))).text,
        )
        assertEquals("Best of 7 so far, 9 seconds up.", LiveWords.compare(r(CompareKind.distance, 1, 7, label = "5K", deltaMs = -9_000)))
        assertEquals("12 seconds behind your only other 5K.", LiveWords.compare(r(CompareKind.distance, 2, 2, label = "5K", deltaMs = 12_000)))
        assertEquals("6 minutes. Heading for about 2,780. VO2 about 51. Second best so far.", CueComposer.compose(CooperProjection.cue(6, 2_780.0), LiveWords.compare(r(CompareKind.cooper, 2, 4, deltaVo2 = -1.0))).text)
        assertEquals("On pace for 24:12. 8 seconds up on your predicted 24:30.", CueComposer.compose("On pace for 24:12", LiveWords.compare(r(CompareKind.target, 1, 1, label = "predicted", deltaMs = -8_000, value = 1_470_000.0))).text)
        assertEquals("Recover. Best start to this session you've had.", CueComposer.compose("Recover", LiveWords.compare(r(CompareKind.intervals, 1, 5, index = 3, deltaSec = -2.0))).text)
        assertEquals("Number 3 of 7, 1 second off your best.", LiveWords.compare(r(CompareKind.distance, 3, 7, deltaMs = 1_000)))
    }

    @Test
    fun `budget - the compare outranks the nudge, an extra that does not fit is dropped, never queued`() {
        val base = "one two three four five six seven eight"
        val fits = CueComposer.compose(base, "a b c d e f", "x y z")
        assertTrue(fits.compareSpoken)
        assertFalse(fits.nudgeSpoken, "8 + 6 + 3 > 16: the nudge goes")
        assertEquals("$base. a b c d e f", fits.text)
        val over = CueComposer.compose(base, "a b c d e f g h i", "x y")
        assertFalse(over.compareSpoken)
        assertTrue(over.nudgeSpoken)
        assertEquals(base, CueComposer.compose(base, null, null).text)
    }
}
