package app.runsolo.core.live

import app.runsolo.core.journal.JournalCodec
import app.runsolo.core.journal.JournalLine
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

/**
 * Mid-run two-button prompts: the trigger rules, the cap and spacing, the 8 s timeout that holds, the headset mapping
 * and what a choice does to the target. All times are data (run ms), never a clock.
 */
class CoachPrompterTest {
    private fun facts(
        km: Int,
        gapMs: Long? = null,
        goal: Double? = null,
        behind: Long? = null,
        chase: Boolean = true,
        label: String? = "5K",
        proxy: Boolean = false,
    ) = KmFacts(km, gapMs, label, proxy, goal, behind, chase)

    /** A km mark at a steady 5:00/km, the runner at [km] km at [km * 300] s. */
    private fun km(p: CoachPrompter, f: KmFacts) = p.atKm(f, f.km * 300_000L, f.km * 1_000.0 + 2)

    // ---- triggers ----

    @Test
    fun `last 2 km of a 5K goal asks push or hold with the gap in the chase words`() {
        val p = CoachPrompter()
        val q = assertNotNull(km(p, facts(3, gapMs = -8_000, goal = 5_000.0)))
        assertEquals(PromptKind.last2k, q.kind)
        assertEquals("2 k to go, 8 seconds up on your best 5K. Push or hold?", q.text)
        assertEquals(listOf(PromptChoice.push, PromptChoice.hold), q.options)
        assertEquals(3, q.km)
    }

    @Test
    fun `a proxy board says pace and never best`() {
        val q = assertNotNull(km(CoachPrompter(), facts(6, gapMs = 10_000, goal = 8_000.0, label = "10K", proxy = true)))
        assertEquals("2 k to go, 10 seconds off your 10K pace. Push or hold?", q.text)
        assertFalse(q.text.contains("best"))
    }

    @Test
    fun `last 2 km without a base still asks and a 3 km goal never does`() {
        assertEquals("2 k to go. Push or hold?", km(CoachPrompter(), facts(3, goal = 5_000.0))!!.text)
        assertNull(km(CoachPrompter(), facts(2, goal = 3_000.0)))
        assertEquals("2.5 k to go. Push or hold?", km(CoachPrompter(), facts(5, goal = 7_500.0))!!.text)
    }

    @Test
    fun `behind the goal target by 15 s asks push or ease off`() {
        val q = assertNotNull(km(CoachPrompter(), facts(3, goal = 10_000.0, behind = 20_000)))
        assertEquals(PromptKind.behindTarget, q.kind)
        assertEquals("20 seconds behind the target. Push or ease off?", q.text)
        assertEquals(listOf(PromptChoice.push, PromptChoice.ease), q.options)
        assertNull(km(CoachPrompter(), facts(3, goal = 10_000.0, behind = 14_000)), "under 15 s is not falling behind")
    }

    @Test
    fun `chase run behind its PB window by 15 s asks the same and names the board`() {
        val q = assertNotNull(km(CoachPrompter(), facts(3, gapMs = 18_000)))
        assertEquals(PromptKind.behindTarget, q.kind)
        assertEquals("18 seconds off your best 5K. Push or ease off?", q.text)
    }

    @Test
    fun `steady has no PB gap so only the goal target and the last 2 km can ask`() {
        assertNull(km(CoachPrompter(), facts(3, gapMs = 40_000, chase = false)))
        assertNull(km(CoachPrompter(), facts(3, gapMs = -40_000, chase = false)))
        assertNotNull(km(CoachPrompter(), facts(3, behind = 30_000, chase = false)))
        assertNotNull(km(CoachPrompter(), facts(3, goal = 5_000.0, chase = false)))
    }

    @Test
    fun `ahead of the PB by a clear margin asks push or hold`() {
        val q = assertNotNull(km(CoachPrompter(), facts(3, gapMs = -15_000)))
        assertEquals(PromptKind.aheadOfPb, q.kind)
        assertEquals("15 seconds up on your best 5K. Push or hold?", q.text)
        assertNull(km(CoachPrompter(), facts(3, gapMs = -11_000)), "11 s is not a clear margin")
    }

    @Test
    fun `last 2 km beats behind beats ahead at one km`() {
        assertEquals(PromptKind.last2k, km(CoachPrompter(), facts(3, gapMs = 30_000, goal = 5_000.0, behind = 30_000))!!.kind)
        assertEquals(PromptKind.behindTarget, km(CoachPrompter(), facts(3, gapMs = -30_000, behind = 30_000))!!.kind)
    }

    @Test
    fun `no gap and no target and no goal says nothing`() {
        assertNull(km(CoachPrompter(), facts(3)))
        assertNull(km(CoachPrompter(), facts(3, gapMs = 2_000)))
    }

    @Test
    fun `between reps asks after a rep that is not the last`() {
        val p = CoachPrompter(distanceGate = false)
        val q = assertNotNull(p.atRepEnd(2, 4, 700_000, 2_400.0))
        assertEquals(PromptKind.betweenReps, q.kind)
        assertEquals("Rep 2 done. Push the next one or hold?", q.text)
        assertEquals(listOf(PromptChoice.push, PromptChoice.hold), q.options)
        assertNull(CoachPrompter(distanceGate = false).atRepEnd(4, 4, 700_000, 2_400.0), "never after the last rep")
    }

    // ---- first km, spacing and the cap ----

    @Test
    fun `never in the first km`() {
        assertNull(CoachPrompter().atKm(facts(1, gapMs = -30_000), 280_000, 1_001.0))
        assertNull(CoachPrompter(distanceGate = false).atRepEnd(1, 4, 240_000, 400.0))
        assertNotNull(CoachPrompter().atKm(facts(2, gapMs = -30_000), 580_000, 2_001.0))
    }

    @Test
    fun `the gap between two prompts is 4 minutes and 1 km on a distance run`() {
        val p = CoachPrompter()
        val a = assertNotNull(p.atKm(facts(2, gapMs = -30_000), 600_000, 2_000.0))
        p.opened(a, 2_000.0)
        p.answer(a.id, 0, PromptSource.tap, 606_000)
        // 3 min and 1 km later: too soon in time.
        assertNull(p.atKm(facts(3, gapMs = -30_000), 780_000, 3_050.0))
        // 4 min later but under 1 km: too soon in distance.
        assertNull(p.atKm(facts(3, gapMs = -30_000), 850_000, 2_900.0))
        // 4 min and 1 km later: allowed.
        assertNotNull(p.atKm(facts(3, gapMs = -30_000), 850_000, 3_050.0))
    }

    @Test
    fun `an interval session has no distance gate only the 4 minutes`() {
        val p = CoachPrompter(distanceGate = false)
        val a = assertNotNull(p.atRepEnd(2, 8, 600_000, 2_000.0))
        p.opened(a, 2_000.0)
        p.answer(a.id, 1, PromptSource.tap, 603_000)
        assertNull(p.atRepEnd(3, 8, 700_000, 2_400.0))
        assertNotNull(p.atRepEnd(4, 8, 850_000, 2_800.0))
    }

    @Test
    fun `at most 3 a run and never while one is open`() {
        val p = CoachPrompter(distanceGate = false)
        var now = 600_000L
        var opened = 0
        for (rep in 2..9) {
            val q = p.atRepEnd(rep, 10, now, rep * 1_000.0)
            if (q != null) {
                p.opened(q, rep * 1_000.0)
                opened++
                assertNull(p.atRepEnd(rep + 1, 10, now + 300_000, 9_000.0), "one is open")
                p.answer(q.id, 0, PromptSource.tap, now + 2_000)
            }
            now += 300_000
        }
        assertEquals(CoachPrompter.MAX_PROMPTS, opened)
        assertEquals(3, p.prompts)
    }

    @Test
    fun `last 2 km is asked once`() {
        val p = CoachPrompter()
        val a = assertNotNull(km(p, facts(3, goal = 5_000.0)))
        p.opened(a, 3_000.0)
        p.answer(a.id, 0, PromptSource.tap, 905_000)
        assertNull(p.atKm(facts(4, goal = 5_000.0), 1_500_000, 4_050.0))
    }

    // ---- the clock: 8 s then hold ----

    private fun open(p: CoachPrompter, at: Long = 900_000): Prompt {
        val q = assertNotNull(p.atKm(facts(3, goal = 5_000.0), at, 3_002.0))
        val o = q.copy(openedAtMs = at)
        p.opened(o, 3_002.0)
        return o
    }

    @Test
    fun `no tap in 8 s holds the current target and says so`() {
        val p = CoachPrompter()
        val q = open(p)
        assertNull(p.tick(q.openedAtMs + 7_999))
        val a = assertNotNull(p.tick(q.openedAtMs + 8_000))
        assertEquals(PromptChoice.hold, a.choice)
        assertEquals(PromptSource.timeout, a.source)
        assertEquals("No answer. Holding.", a.spoken)
        assertNull(p.open)
        assertEquals(PromptEffect.NONE, p.effect, "a timeout changes nothing")
        assertNull(p.tick(q.openedAtMs + 9_000), "answered once")
    }

    @Test
    fun `a tap answers with its button and a late tap or a wrong id does nothing`() {
        val p = CoachPrompter()
        val q = open(p)
        assertNull(p.answer(q.id + 1, 0, PromptSource.tap, q.openedAtMs + 1_000), "another prompt")
        assertNull(p.answer(q.id, 2, PromptSource.tap, q.openedAtMs + 1_000), "no third button")
        val a = assertNotNull(p.answer(q.id, 1, PromptSource.tap, q.openedAtMs + 2_000))
        assertEquals(PromptChoice.hold, a.choice)
        assertEquals(PromptSource.tap, a.source)
        assertEquals("Holding.", a.spoken)
        assertNull(p.answer(q.id, 0, PromptSource.tap, q.openedAtMs + 3_000), "already answered")
    }

    @Test
    fun `the first button is push on a last 2 km and ease is the second on behind`() {
        val p = CoachPrompter()
        val q = open(p)
        assertEquals("Pushing.", p.answer(q.id, 0, PromptSource.tap, q.openedAtMs + 1_000)!!.spoken)
        val e = CoachPrompter()
        val b = assertNotNull(e.atKm(facts(3, behind = 20_000), 900_000, 3_002.0))
        e.opened(b, 3_002.0)
        val a = assertNotNull(e.answer(b.id, 1, PromptSource.tap, 902_000))
        assertEquals(PromptChoice.ease, a.choice)
        assertEquals("Easing off.", a.spoken)
    }

    // ---- headset ----

    @Test
    fun `one press waits out the double window then answers the first option`() {
        val h = HeadsetPresses()
        assertNull(h.press(1_000))
        assertTrue(h.pending)
        assertNull(h.poll(1_449))
        assertEquals(0, h.poll(1_450))
        assertFalse(h.pending)
        assertNull(h.poll(2_000))
    }

    @Test
    fun `two quick presses answer the second option at once`() {
        val h = HeadsetPresses()
        assertNull(h.press(1_000))
        assertEquals(1, h.press(1_300))
        assertNull(h.poll(2_000), "the pair is spent")
        // A slow second press is a new first press.
        assertNull(h.press(5_000))
        assertNull(h.press(5_600))
        assertEquals(0, h.poll(6_100))
    }

    @Test
    fun `a headset press while a prompt is open answers it and says headset`() {
        val p = CoachPrompter()
        val q = open(p)
        val t = q.openedAtMs + 1_000
        assertNull(p.headsetPress(t))
        assertTrue(p.headsetPending)
        val single = assertNotNull(p.tick(t + 460))
        assertEquals(PromptChoice.push, single.choice)
        assertEquals(PromptSource.headset, single.source)
        // Another prompt, a double press.
        val p2 = CoachPrompter()
        val q2 = open(p2)
        assertNull(p2.headsetPress(q2.openedAtMs + 1_000))
        val dbl = assertNotNull(p2.headsetPress(q2.openedAtMs + 1_250))
        assertEquals(PromptChoice.hold, dbl.choice)
        assertEquals(PromptSource.headset, dbl.source)
    }

    @Test
    fun `a press with no prompt open is nothing - the lap stays the lap`() {
        val p = CoachPrompter()
        assertNull(p.headsetPress(1_000))
        assertFalse(p.headsetPending)
    }

    @Test
    fun `an unanswered single press times out as a hold with the prompt`() {
        val p = CoachPrompter()
        val q = open(p)
        p.headsetPress(q.openedAtMs + 7_800)
        // The wait fires after the window (a push) before the 8 s timeout.
        assertEquals(PromptSource.headset, p.tick(q.openedAtMs + 8_300)!!.source)
    }

    // ---- effect on the target ----

    @Test
    fun `push tightens 3 percent and doubles the cue rate - hold changes nothing - ease loosens`() {
        assertEquals(291.0, PromptEffect.PUSH.targetPace(300.0)!!, 1e-9)
        assertEquals(312.0, PromptEffect.EASE.targetPace(300.0)!!, 1e-9)
        assertEquals(300.0, PromptEffect.NONE.targetPace(300.0)!!, 1e-9)
        assertNull(PromptEffect.PUSH.targetPace(null))
        assertEquals(PromptEffect.PUSH, PromptEffect.NONE.after(PromptChoice.push))
        assertEquals(PromptEffect.PUSH, PromptEffect.PUSH.after(PromptChoice.hold), "hold keeps the push")
        assertEquals(PromptEffect.EASE, PromptEffect.PUSH.after(PromptChoice.ease), "a later answer replaces")
        assertTrue(PromptEffect.PUSH.everyFactor < 1.0 && PromptEffect.EASE.everyFactor > 1.0)
    }

    @Test
    fun `the prompter keeps the effect of the last push or ease`() {
        val p = CoachPrompter(distanceGate = false)
        val a = assertNotNull(p.atRepEnd(2, 8, 600_000, 2_000.0))
        p.opened(a, 2_000.0)
        p.answer(a.id, 0, PromptSource.tap, 602_000)
        assertEquals(PromptEffect.PUSH, p.effect)
        val b = assertNotNull(p.atRepEnd(4, 8, 900_000, 3_000.0))
        p.opened(b, 3_000.0)
        p.tick(b.openedAtMs + 8_000) // times out: hold
        assertEquals(PromptEffect.PUSH, p.effect, "hold by timeout keeps the push")
    }

    // ---- the voice coach follows the effect ----

    private val target = 300.0

    private fun coach(fallback: Boolean = false) =
        VoiceCoach(VoiceCoach.Config(true, targetPaceSecPerKm = if (fallback) null else target))

    private fun VoiceCoach.run(toS: Int, pace: Double): List<Pair<Int, String>> = (0..toS).mapNotNull { s ->
        tick(VoiceCoach.Input(s * 1_000L, 0, s * 1_000L, pace, null, null, 0))?.let { s to it.text }
    }

    @Test
    fun `after a push the same pace is slow against the tighter target`() {
        assertEquals(listOf(30 to "On pace"), coach().run(30, 300.0))
        val c = coach()
        c.applyEffect(PromptEffect.PUSH, null)
        assertEquals(listOf(30 to "Pick it up, 9 seconds slow"), c.run(30, 300.0))
    }

    @Test
    fun `after an ease off a pace that was slow is on pace`() {
        assertEquals(listOf(30 to "Pick it up, 8 seconds slow"), coach().run(30, 308.0))
        val c = coach()
        c.applyEffect(PromptEffect.EASE, null)
        assertEquals(listOf(30 to "On pace"), c.run(30, 308.0))
    }

    @Test
    fun `a push checks twice as often`() {
        val c = coach()
        c.applyEffect(PromptEffect.PUSH, null)
        assertEquals(listOf(30, 60, 90), c.run(100, 308.0).map { it.first })
    }

    @Test
    fun `a chase run with no target races the PB pace once pushed and not before`() {
        val none = coach(fallback = true)
        none.applyEffect(PromptEffect.NONE, 300.0)
        assertEquals(emptyList(), none.run(60, 300.0), "hold or no answer: no target appears")
        val c = coach(fallback = true)
        c.applyEffect(PromptEffect.PUSH, 300.0)
        assertEquals(30 to "Pick it up, 9 seconds slow", c.run(30, 300.0).single())
        val noPace = coach(fallback = true)
        noPace.applyEffect(PromptEffect.PUSH, null)
        assertEquals(emptyList(), noPace.run(60, 300.0), "no PB pace to tighten")
    }

    // ---- the journal line ----

    @Test
    fun `an answer is a pr journal line that round trips and restores the count and the effect`() {
        val p = CoachPrompter()
        val q = open(p)
        val a = assertNotNull(p.answer(q.id, 0, PromptSource.headset, q.openedAtMs + 3_000))
        val line = CoachPrompter.line(a, 1_700_000_000_000, 903_000)
        assertEquals(
            """{"k":"pr","t":903000,"w":1700000000000,"id":${q.id},"trig":"last2k","km":3,"opts":["push","hold"],"choice":"push","src":"headset","open":900000,"at":903000}""",
            JournalCodec.encode(line),
        )
        assertEquals(line, JournalCodec.decode(JournalCodec.encode(line)))
        val back = CoachPrompter(CoachPrompter.restore(listOf(line)))
        assertEquals(1, back.prompts)
        assertEquals(PromptEffect.PUSH, back.effect)
        // The next prompt id does not repeat, and the last-2-km question is not asked again.
        assertNull(back.atKm(facts(4, goal = 5_000.0), 1_500_000, 4_050.0))
        assertTrue(line is JournalLine.PromptResolved)
    }
    @Test
    fun `a goal runner who is behind all the way still gets the last 2 km question`() {
        // Behind the target at every km of an 8 km goal: km 2 and 3 ask, km 4 and 5 are held back, km 6 asks.
        val p = CoachPrompter()
        val asked = mutableListOf<PromptKind>()
        for (k in 2..6) {
            val f = facts(k, goal = 8_000.0, behind = 40_000)
            val q = p.atKm(f, k * 352_000L, k * 1_000.0 + 2)
            if (q != null) {
                asked += q.kind
                p.opened(q, k * 1_000.0 + 2)
                p.answer(q.id, 0, PromptSource.tap, q.openedAtMs + 2_000) // push
            }
        }
        assertEquals(listOf(PromptKind.behindTarget, PromptKind.behindTarget, PromptKind.last2k), asked)
    }

    @Test
    fun `after an ease off the falling behind question is not asked again`() {
        val p = CoachPrompter()
        val a = assertNotNull(p.atKm(facts(2, behind = 40_000), 600_000, 2_002.0))
        p.opened(a, 2_002.0)
        assertEquals(PromptChoice.ease, p.answer(a.id, 1, PromptSource.tap, 603_000)!!.choice)
        assertNull(p.atKm(facts(4, behind = 60_000), 1_300_000, 4_002.0))
        // A restore keeps it.
        val line = JournalLine.PromptResolved(603_000, 1, a.id, "behindTarget", 2, listOf("push", "ease"), "ease", "tap", 600_000, 603_000)
        assertNull(CoachPrompter(CoachPrompter.restore(listOf(line))).atKm(facts(4, behind = 60_000), 1_300_000, 4_002.0))
        // Ahead of the PB can still ask.
        assertNotNull(p.atKm(facts(4, gapMs = -20_000), 1_300_000, 4_002.0))
    }
}
