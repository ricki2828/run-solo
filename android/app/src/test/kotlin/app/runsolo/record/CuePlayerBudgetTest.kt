package app.runsolo.record

import android.content.Context
import app.runsolo.core.live.CueSlot
import app.runsolo.core.live.TalkLine
import app.runsolo.core.live.VoiceLevel
import app.runsolo.core.model.CueKind
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.annotation.Config

/** Every spoken line goes through the TalkBudget: a turn is never dropped, a km or game beat waits its turn. */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34])
class CuePlayerBudgetTest {
    private val context: Context = RuntimeEnvironment.getApplication()
    private var clock = 0L

    private fun coachPlayer() = CuePlayer(context) { clock }.also { it.voiceLevel = VoiceLevel.coach }

    @Test
    fun `a km line right after a turn is dropped and said once the gap has passed`() {
        val cues = coachPlayer()
        cues.alert("Turn here.", longArrayOf(0, 150), CueSlot.turnaround)
        clock = 10_000
        assertNull(cues.play(null, "4 k.", null, key = "km:4"))
        clock = 40_000
        assertEquals("5 k.", cues.play(null, "5 k.", null, key = "km:5")?.text)
    }

    @Test
    fun `an interval cue is structure and is always said`() {
        val cues = coachPlayer()
        cues.announce("one two three four five six seven eight nine ten")
        clock = 100
        assertNotNull(cues.play(CueKind.phaseEnd, "Recover.", null))
    }

    @Test
    fun `a game beat held behind a cue is said when the gap opens`() {
        val cues = coachPlayer()
        cues.alert("Turn here.", longArrayOf(0, 150), CueSlot.turnaround)
        clock = 18_000
        assertNull(cues.moment(TalkLine(CueSlot.climbAhead, "climbAhead:0", "Climb ahead. 70 metres up.")))
        clock = 26_000
        assertEquals("Climb ahead. 70 metres up.", cues.dueMoment()?.text)
        assertNull(cues.dueMoment())
    }

    @Test
    fun `a quest done line held behind a km cue is said by dueMoment once the gap opens`() {
        val cues = coachPlayer()
        // The km cue and the quest completing on the same tick: the km goes first.
        assertNotNull(cues.play(null, "5 k.", null, key = "km:5"))
        val quest = TalkLine(CueSlot.questDone, "questDone:q_x", "Saddle number five. Quest done.", holdMs = 30_000L)
        clock = 100
        assertNull(cues.moment(quest))
        // Past the usual 10 s hold, still waiting for the gap after the km cue.
        clock = 12_000
        assertNull(cues.dueMoment())
        clock = 27_000
        assertEquals("Saddle number five. Quest done.", cues.dueMoment()?.text)
        assertNull(cues.dueMoment())
    }

    @Test
    fun `hard effort keeps the km quiet`() {
        val cues = coachPlayer()
        cues.hardEffort = true
        assertNull(cues.play(null, "4 k.", null, key = "km:4"))
        cues.hardEffort = false
        assertEquals("4 k.", cues.play(null, "4 k.", null, key = "km:4")?.text)
    }

    @Test
    fun `a km line with a compare is said inside the gap and not reported as dropped`() {
        val cues = coachPlayer()
        cues.alert("Turn here.", longArrayOf(0, 150), CueSlot.turnaround)
        clock = 5_000
        val said = cues.play(null, "3 k.", "2nd of 7, 5 seconds off your best.", key = "km:3")
        assertEquals("3 k. 2nd of 7, 5 seconds off your best.", said?.text)
        assertEquals(false, cues.consumeDropped())
    }

    @Test
    fun `a dropped km line says so once and a plain one is dropped inside the gap`() {
        val cues = coachPlayer()
        cues.alert("Turn here.", longArrayOf(0, 150), CueSlot.turnaround)
        clock = 5_000
        assertNull(cues.play(null, "3 k.", null, key = "km:3"))
        assertEquals(true, cues.consumeDropped())
        assertEquals(false, cues.consumeDropped())
        cues.hardEffort = true
        assertNull(cues.play(null, "4 k.", "2nd of 7, 5 seconds off your best.", key = "km:4"))
        assertEquals(true, cues.consumeDropped())
    }

    @Test
    fun `voice coaching waits for the budget gap on Coach and not on Everything`() {
        val cues = coachPlayer()
        cues.alert("Turn here.", longArrayOf(0, 150), CueSlot.turnaround)
        clock = 1_000
        assertEquals(25_750L, cues.coachBusyUntil)
        // Everything: just the speech queue (this player's alert starts at clock 1000, 2 words = 750 ms), no budget gap.
        assertEquals(1_750L, CuePlayer(context) { clock }.also { it.alert("Turn here.", longArrayOf(0, 150)) }.coachBusyUntil)
    }

    @Test
    fun `the default level only de-dupes`() {
        val cues = CuePlayer(context) { clock }
        cues.alert("Turn here.", longArrayOf(0, 150), CueSlot.turnaround)
        clock = 1_000
        assertEquals("1 k.", cues.play(null, "1 k.", null, key = "km:1")?.text)
    }
}
