package app.runsolo.core.live

import app.runsolo.core.model.LiveQuest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

class QuestBeatTest {
    private fun counter(kind: String, remaining: Double) =
        LiveQuest("q_2026-11_${kind}_aa", kind, "TITLE", "Quest line.", remaining = remaining, trailId = if (kind == LiveQuest.TRAIL_VISITS) "trail:x" else null)

    @Test
    fun `climb month fires once when the barometer ascent reaches what is left`() {
        val b = QuestBeat(counter(LiveQuest.CLIMB_MONTH, 320.0))
        assertNull(b.tick(QuestInput(1_000, 2_000.0, ascentM = 319.0)))
        assertNull(b.tick(QuestInput(2_000, 2_100.0, ascentM = null)))
        val line = b.tick(QuestInput(3_000, 2_200.0, ascentM = 320.0))
        assertNotNull(line)
        assertEquals(CueSlot.questDone, line.slot)
        assertEquals("questDone:q_2026-11_climb_month_aa", line.key)
        assertEquals("Quest line.", line.text)
        b.spend()
        assertNull(b.tick(QuestInput(4_000, 2_300.0, ascentM = 400.0)))
        assertTrue(b.isSpent)
    }

    @Test
    fun `the session spends the beat before offering the line so a held line is released by the budget not by the beat`() {
        val b = QuestBeat(counter(LiveQuest.DISTANCE_MONTH, 5_000.0))
        val line = b.tick(QuestInput(1_000, 5_000.0))
        assertNotNull(line)
        // The session's order: spend and journal first, then offer to the budget.
        b.spend()
        assertNull(b.tick(QuestInput(2_000, 5_010.0)))
        val budget = TalkBudget(VoiceLevel.coach)
        // Speech is in the way (a km cue just ended): the budget holds the P1 line.
        assertNotNull(budget.offer(TalkLine(CueSlot.turnaround, "t", "Turn here."), 1_000L, 0L))
        assertNull(budget.offer(line, 1_100L, 0L))
        // Still waiting at 18 s; the poll releases it once the gap opens, inside its own 30 s hold, and only once.
        assertNull(budget.poll(18_000L, 0L))
        val due = budget.poll(27_000L, 0L)
        assertEquals(line.text, due?.text)
        assertNull(budget.poll(27_100L, 0L))
    }

    @Test
    fun `distance month fires at the remaining distance`() {
        val b = QuestBeat(counter(LiveQuest.DISTANCE_MONTH, 4_200.0))
        assertNull(b.tick(QuestInput(1_000, 4_199.0)))
        assertNotNull(b.tick(QuestInput(2_000, 4_200.0)))
    }

    @Test
    fun `the last trail visit fires near the end of its own trail and not off the line`() {
        val b = QuestBeat(counter(LiveQuest.TRAIL_VISITS, 1.0))
        assertNull(b.tick(QuestInput(1_000, 3_000.0, ghostTrailId = "trail:x", toGoM = 400.0)))
        assertNull(b.tick(QuestInput(2_000, 3_300.0, ghostTrailId = "trail:y", toGoM = 100.0)))
        assertNull(b.tick(QuestInput(3_000, 3_300.0, ghostTrailId = "trail:x", toGoM = 100.0, off = true)))
        assertNull(b.tick(QuestInput(4_000, 3_300.0, ghostTrailId = null, toGoM = null)))
        assertNotNull(b.tick(QuestInput(5_000, 3_350.0, ghostTrailId = "trail:x", toGoM = 149.0)))
    }

    @Test
    fun `an earlier visit has no live line`() {
        val b = QuestBeat(counter(LiveQuest.TRAIL_VISITS, 2.0))
        assertNull(b.tick(QuestInput(1_000, 3_300.0, ghostTrailId = "trail:x", toGoM = 10.0)))
    }

    private val climb = LiveQuest(
        "q_2026-11_climb_best_aa", LiveQuest.CLIMB_BEST, "THE 1.2 K CLIMB", "Best ever up the climb. Quest done.",
        trailId = "trail:x", climbStartM = 1_200.0, climbEndM = 2_400.0, targetMs = 580_000L,
    )

    @Test
    fun `climb best fires at the top when the time from the foot beat the target`() {
        val b = QuestBeat(climb)
        assertNull(b.tick(QuestInput(100_000, 1_000.0, ghostTrailId = "trail:x", alongM = 1_000.0)))
        assertNull(b.tick(QuestInput(120_000, 1_210.0, ghostTrailId = "trail:x", alongM = 1_210.0)))
        assertNull(b.tick(QuestInput(400_000, 1_900.0, ghostTrailId = "trail:x", alongM = 1_900.0)))
        // Foot seen at 120 s, top at 690 s: 570 s, under the 580 s target.
        assertNotNull(b.tick(QuestInput(690_000, 2_410.0, ghostTrailId = "trail:x", alongM = 2_410.0)))
    }

    @Test
    fun `climb best does not fire when too slow or the foot was not seen or on another trail`() {
        val slow = QuestBeat(climb)
        slow.tick(QuestInput(100_000, 1_210.0, ghostTrailId = "trail:x", alongM = 1_210.0))
        assertNull(slow.tick(QuestInput(700_000, 2_410.0, ghostTrailId = "trail:x", alongM = 2_410.0)))
        val joined = QuestBeat(climb)
        // First seen halfway up: the foot is unknown.
        joined.tick(QuestInput(100_000, 1_800.0, ghostTrailId = "trail:x", alongM = 1_800.0))
        assertNull(joined.tick(QuestInput(200_000, 2_410.0, ghostTrailId = "trail:x", alongM = 2_410.0)))
        val other = QuestBeat(climb)
        other.tick(QuestInput(100_000, 1_210.0, ghostTrailId = "trail:y", alongM = 1_210.0))
        assertNull(other.tick(QuestInput(300_000, 2_410.0, ghostTrailId = "trail:y", alongM = 2_410.0)))
    }

    @Test
    fun `a restore forgets a climb under way and a spent beat stays spent`() {
        val b = QuestBeat(climb)
        b.tick(QuestInput(100_000, 1_210.0, ghostTrailId = "trail:x", alongM = 1_210.0))
        b.resumeAt()
        assertNull(b.tick(QuestInput(300_000, 2_410.0, ghostTrailId = "trail:x", alongM = 2_410.0)))
        val spent = QuestBeat(counter(LiveQuest.DISTANCE_MONTH, 100.0), spent = true)
        assertNull(spent.tick(QuestInput(1_000, 5_000.0)))
    }

    @Test
    fun `the quest done slot is a P1 game beat said once per key`() {
        assertEquals(1, CueSlot.questDone.priority)
        val b = TalkBudget(VoiceLevel.coach)
        val line = TalkLine(CueSlot.questDone, "questDone:q_x", "Quest line. Done now.")
        assertNotNull(b.offer(line, 5_000L, 0L))
        assertNull(b.offer(line, 60_000L, 0L))
    }

    @Test
    fun `a quest line takes the held slot from another game beat and outlasts the usual hold`() {
        val b = TalkBudget(VoiceLevel.coach)
        assertNotNull(b.offer(TalkLine(CueSlot.turnaround, "t", "Turn here."), 1_000L, 0L))
        assertNull(b.offer(TalkLine(CueSlot.climbAhead, "c", "Climb ahead. 70 metres up."), 2_000L, 0L))
        val quest = QuestBeat(counter(LiveQuest.DISTANCE_MONTH, 100.0)).tick(QuestInput(3_000, 200.0))!!
        assertNull(b.offer(quest, 3_000L, 0L))
        // Past the usual 10 s hold, the quest line is still waiting and is said when the gap opens.
        assertEquals(quest.text, b.poll(27_500L, 0L)?.text)
    }

    @Test
    fun `minimal voice says no quest line`() {
        val b = TalkBudget(VoiceLevel.minimal)
        assertNull(b.offer(TalkLine(CueSlot.questDone, "questDone:q_x", "Quest line. Done now."), 5_000L, 0L))
    }
}
