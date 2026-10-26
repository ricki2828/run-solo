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
        goalMs: Long? = null,
    ) = KmFacts(km, gapMs, label, proxy, goal, behind, chase, goalMs)

    /** A km mark at a steady 5:00/km, the runner at [km] km at [km * 300] s. */
    private fun km(p: CoachPrompter, f: KmFacts) = p.atKm(f, f.km * 300_000L, f.km * 1_000.0 + 2)

    /** A goal runner losing ground: km 2 is 10 s behind the target (under the bar), km 3 is [behind] ms behind. */
    private fun fallingBehind(p: CoachPrompter, behind: Long = 30_000, goal: Double? = 10_000.0): Prompt? {
        assertNull(km(p, facts(2, goal = goal, behind = 10_000)))
        return km(p, facts(3, goal = goal, behind = behind))
    }

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
    fun `behind the goal target and still falling back asks push or ease off`() {
        val q = assertNotNull(fallingBehind(CoachPrompter(), behind = 30_000))
        assertEquals(PromptKind.behindTarget, q.kind)
        assertEquals("30 seconds behind the target. Push or ease off?", q.text)
        assertEquals(listOf(PromptChoice.push, PromptChoice.ease), q.options)
    }

    @Test
    fun `behind but not falling back asks nothing - a steady deficit is not news`() {
        val p = CoachPrompter()
        assertNull(km(p, facts(2, goal = 10_000.0, behind = 40_000)), "no last km to compare with")
        assertNull(km(p, facts(3, goal = 10_000.0, behind = 44_000)), "grew by 4 s only")
        assertNotNull(fallingBehind(CoachPrompter(), behind = 20_000), "10 s to 20 s is a 10 s growth and over the 15 s bar")
        assertNull(km(CoachPrompter(), facts(3, goal = 10_000.0, behind = 14_000)), "under 15 s is not behind")
    }
    @Test
    fun `a Free chase run is never asked about falling behind its PB pace`() {
        // An easy 5:52 run against a 5K PB pace is 90 s behind and getting further: not a race, the chase line says it.
        val p = CoachPrompter()
        assertNull(km(p, facts(2, gapMs = 40_000)))
        assertNull(km(p, facts(3, gapMs = 90_000)))
        assertNull(km(p, facts(4, gapMs = 140_000)))
    }
    @Test
    fun `steady never asks behind or ahead - only the last 2 km of a goal`() {
        assertNull(km(CoachPrompter(), facts(3, gapMs = 40_000, chase = false)))
        assertNull(km(CoachPrompter(), facts(3, gapMs = -40_000, chase = false)))
        val p = CoachPrompter()
        assertNull(km(p, facts(2, goal = 10_000.0, behind = 10_000, chase = false)))
        assertNull(km(p, facts(3, goal = 10_000.0, behind = 60_000, chase = false)), "behind the target, growing, in Steady")
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
    fun `last 2 km beats behind and ahead at one km - and behind beats ahead`() {
        val p = CoachPrompter()
        km(p, facts(2, goal = 5_000.0, behind = 10_000))
        assertEquals(PromptKind.last2k, km(p, facts(3, gapMs = -30_000, goal = 5_000.0, behind = 40_000))!!.kind)
        val q = CoachPrompter()
        km(q, facts(2, goal = 10_000.0, behind = 10_000))
        assertEquals(PromptKind.behindTarget, km(q, facts(3, gapMs = -30_000, goal = 10_000.0, behind = 40_000))!!.kind)
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
    fun `the gap between two prompts is 4 minutes and 2 km on a distance run`() {
        val p = CoachPrompter()
        val a = assertNotNull(p.atKm(facts(2, gapMs = -30_000), 600_000, 2_000.0))
        p.opened(a, 2_000.0)
        p.answer(a.id, 0, PromptSource.tap, 606_000)
        // 3 min and 2 km later: too soon in time.
        assertNull(p.atKm(facts(4, gapMs = -30_000), 780_000, 4_050.0))
        // 4 min later but under 2 km: too soon in distance.
        assertNull(p.atKm(facts(3, gapMs = -30_000), 850_000, 3_900.0))
        // 4 min and 2 km later: allowed.
        assertNotNull(p.atKm(facts(4, gapMs = -30_000), 850_000, 4_050.0))
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
    fun `between reps asks at most twice and never after the first rep`() {
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
        assertEquals(CoachPrompter.MAX_REP_PROMPTS, opened)
        assertEquals(2, p.prompts)
        assertNull(CoachPrompter(distanceGate = false).atRepEnd(1, 10, 600_000, 2_000.0), "rep 1 has nothing to compare")
    }

    @Test
    fun `at most 3 a run counting every kind and never while one is open`() {
        val p = CoachPrompter()
        var opened = 0
        var dist = 2_002.0
        var now = 600_000L
        repeat(6) {
            val q = p.atKm(facts((dist / 1000).toInt(), gapMs = -30_000), now, dist)
            if (q != null) {
                p.opened(q, dist)
                opened++
                assertNull(p.atKm(facts((dist / 1000).toInt() + 1, gapMs = -30_000), now + 300_000, dist + 2_000), "one is open")
                p.answer(q.id, 0, PromptSource.tap, now + 2_000)
            }
            dist += 2_000.0
            now += 700_000
        }
        assertEquals(CoachPrompter.MAX_PROMPTS, opened)
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

    /** A last-2-km prompt asked at [at], its answer window started [saidAfter] ms later (the question is said). */
    private fun open(p: CoachPrompter, at: Long = 900_000, saidAfter: Long = 0): Prompt {
        val q = assertNotNull(p.atKm(facts(3, goal = 5_000.0), at, 3_002.0))
        val o = q.copy(openedAtMs = at)
        p.opened(o, 3_002.0)
        p.startWindow(at + saidAfter)
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
        val b = assertNotNull(fallingBehind(e, behind = 40_000))
        e.opened(b, 3_002.0)
        val a = assertNotNull(e.answer(b.id, 1, PromptSource.tap, b.openedAtMs + 2_000))
        assertEquals(PromptChoice.ease, a.choice)
        assertEquals("Easing off.", a.spoken)
    }
    // ---- the answer window ----

    @Test
    fun `the 8 s window starts when the question has been said not when it was asked`() {
        val p = CoachPrompter()
        val q = open(p, at = 900_000, saidAfter = 5_000) // 5 s of speech before the window
        assertNull(p.tick(q.openedAtMs + 9_000), "9 s after it was asked is not 8 s after it was said")
        assertEquals(4_000L, p.remainingMs(q.openedAtMs + 9_000))
        val a = assertNotNull(p.tick(q.openedAtMs + 13_000))
        assertEquals(PromptSource.timeout, a.source)
        assertEquals(q.openedAtMs + 5_000, a.windowStartMs, "the log carries when the window started")
    }

    @Test
    fun `a window that never started never times out - the caller starts it with its fallback`() {
        val p = CoachPrompter()
        val q = assertNotNull(p.atKm(facts(3, goal = 5_000.0), 900_000, 3_002.0))
        p.opened(q, 3_002.0)
        assertFalse(p.windowStarted)
        assertEquals(CoachPrompter.TIMEOUT_MS, p.remainingMs(950_000))
        assertNull(p.tick(950_000))
        p.startWindow(950_000)
        assertTrue(p.windowStarted)
        assertNotNull(p.tick(958_000))
    }

    @Test
    fun `a tap while the question is still being said answers it`() {
        val p = CoachPrompter()
        val q = assertNotNull(p.atKm(facts(3, goal = 5_000.0), 900_000, 3_002.0))
        p.opened(q, 3_002.0)
        assertEquals(PromptChoice.push, p.answer(q.id, 0, PromptSource.tap, 901_000)!!.choice)
    }

    @Test
    fun `a paused run freezes the window - a runner at the lights can still answer`() {
        val p = CoachPrompter()
        val q = open(p, at = 900_000)
        p.hold(20_000) // 20 s stopped
        assertNull(p.tick(q.openedAtMs + 27_000), "7 s of window used")
        assertEquals(1_000L, p.remainingMs(q.openedAtMs + 27_000))
        assertNotNull(p.tick(q.openedAtMs + 28_000))
        // A hold before the window started changes nothing.
        val r = CoachPrompter()
        val a = assertNotNull(r.atKm(facts(3, goal = 5_000.0), 900_000, 3_002.0))
        r.opened(a, 3_002.0)
        r.hold(20_000)
        r.startWindow(930_000)
        assertNull(r.tick(937_999))
        assertNotNull(r.tick(938_000))
    }

    @Test
    fun `a long manual pause closes the open prompt as a quiet hold and a short one only waits`() {
        val p = CoachPrompter()
        val q = open(p, at = 900_000)
        assertNull(p.manualPause(29_999, q.openedAtMs + 29_999), "the lights: still open")
        assertNotNull(p.open)
        val a = assertNotNull(p.manualPause(CoachPrompter.MANUAL_PAUSE_CLOSE_MS, q.openedAtMs + 30_000))
        assertEquals(PromptChoice.hold, a.choice)
        assertEquals(PromptSource.timeout, a.source)
        assertTrue(a.quiet)
        assertNull(a.spoken, "nothing said to a runner who stopped")
        assertNull(p.open, "the headset is free again")
        assertEquals(PromptEffect.NONE, p.effect)
        assertNull(p.manualPause(60_000, q.openedAtMs + 60_000), "closed once")
        assertNull(p.tick(q.openedAtMs + 60_000))
        assertEquals(1, p.prompts, "it still counts toward the cap")
        // The journal line is an ordinary timeout hold.
        assertEquals("timeout", CoachPrompter.line(a, 0, 0).source)
    }

    @Test
    fun `a manual pause before the question is said closes it too - nothing open is nothing`() {
        assertNull(CoachPrompter().manualPause(120_000, 900_000))
        val r = CoachPrompter()
        val a = assertNotNull(r.atKm(facts(3, goal = 5_000.0), 900_000, 3_002.0))
        r.opened(a, 3_002.0)
        assertFalse(r.windowStarted)
        assertTrue(assertNotNull(r.manualPause(30_000, 930_000)).quiet)
    }

    @Test
    fun `once a tick - auto-pause only waits and an unbroken manual pause of 30 s closes the prompt quietly`() {
        val p = CoachPrompter()
        val q = open(p, at = 900_000)
        var t = q.openedAtMs
        fun tick(paused: Boolean, manual: Boolean = paused, s: Int = 1): PromptAnswer? {
            var out: PromptAnswer? = null
            repeat(s) {
                t += 1_000
                out = p.pauseTick(t, paused, manual) ?: p.tick(t)
                if (out != null) return out
            }
            return out
        }
        assertNull(p.pauseTick(t, paused = false, manual = false))
        assertNull(tick(paused = true, manual = false, s = 60), "a minute at the lights (auto-pause): open and frozen")
        assertEquals(CoachPrompter.TIMEOUT_MS, p.remainingMs(t))
        assertNull(tick(paused = true, s = 20), "a 20 s stop by hand")
        assertNull(tick(paused = false, s = 2), "running again: 2 s of window used")
        assertNull(tick(paused = true, s = 30), "a second stop is counted from its own start: 29 s so far")
        val a = assertNotNull(tick(paused = true))
        assertTrue(a.quiet)
        assertEquals(PromptSource.timeout, a.source)
        assertNull(p.open)
        assertNull(tick(paused = true, s = 40), "nothing open: nothing more")
    }

    // ---- opening a decided prompt (route cues, speech, manual pause) ----

    private fun decide(p: CoachPrompter, at: Long = 900_000): Prompt {
        val q = assertNotNull(p.atKm(facts(3, goal = 5_000.0), at, 3_002.0))
        p.decided(q, at)
        return q
    }

    private fun steps(p: CoachPrompter, from: Long, to: Long, route: (Long) -> Boolean = { false }, speech: (Long) -> Boolean = { false }): Pair<Long, CoachPrompter.PendingStep>? {
        var t = from
        while (t <= to) {
            val s = p.openTick(t, speechBusy = speech(t), routeBusy = route(t), manualPause = false)
            if (s != CoachPrompter.PendingStep.Wait) return t to s
            t += 1_000
        }
        return null
    }

    @Test
    fun `a decided prompt opens after the delay once speech is done`() {
        val p = CoachPrompter()
        val q = decide(p)
        assertEquals(CoachPrompter.PendingStep.Wait, p.openTick(901_000, speechBusy = false, routeBusy = false, manualPause = false))
        val (t, s) = assertNotNull(steps(p, 902_000, 920_000, speech = { it < 905_000 }))
        assertEquals(905_000L, t)
        assertEquals(CoachPrompter.PendingStep.Open(q), s)
        assertNull(p.pending)
        // Speech that never ends is waited out for at most 6 s past the delay.
        val r = CoachPrompter()
        decide(r)
        assertEquals(908_000L, assertNotNull(steps(r, 902_000, 920_000, speech = { true })).first)
    }

    @Test
    fun `a route cue holds the question and the route line goes first`() {
        val p = CoachPrompter()
        val q = decide(p)
        // OFF ROUTE from 901 s to 930 s: nothing opens over it, then 2 s more for "Back on route".
        val (t, s) = assertNotNull(steps(p, 902_000, 990_000, route = { it < 930_000 }))
        assertEquals(932_000L, t)
        assertEquals(CoachPrompter.PendingStep.Open(q), s)
    }

    @Test
    fun `a route cue that lasts past a minute drops the prompt uncounted`() {
        val p = CoachPrompter()
        decide(p)
        val (t, s) = assertNotNull(steps(p, 902_000, 1_000_000, route = { true }))
        assertEquals(CoachPrompter.PendingStep.Drop, s)
        assertEquals(962_000L, t)
        assertNull(p.pending)
        assertEquals(0, p.prompts, "never asked, never counted")
    }

    @Test
    fun `a manual pause at open time drops it`() {
        val p = CoachPrompter()
        decide(p)
        assertEquals(CoachPrompter.PendingStep.Drop, p.openTick(902_000, speechBusy = false, routeBusy = false, manualPause = true))
        assertNull(p.pending)
    }

    @Test
    fun `route busy is off route or the end cue or a turn within 100 m`() {
        assertTrue(CoachPrompter.routeBusy(off = true, endCueUp = false, turnInM = null))
        assertTrue(CoachPrompter.routeBusy(off = false, endCueUp = true, turnInM = null))
        assertTrue(CoachPrompter.routeBusy(off = false, endCueUp = false, turnInM = 100.0))
        assertFalse(CoachPrompter.routeBusy(off = false, endCueUp = false, turnInM = 101.0))
        assertFalse(CoachPrompter.routeBusy(off = false, endCueUp = false, turnInM = null))
        assertTrue(CoachPrompter.routeBusy(off = false, endCueUp = false, turnInM = null, trailTurnCue = true))
    }

    @Test
    fun `a trail turn-around card holds the question and it opens once the card clears`() {
        val p = CoachPrompter()
        val q = decide(p)
        val busy = { t: Long -> CoachPrompter.routeBusy(off = false, endCueUp = false, turnInM = null, trailTurnCue = t < 930_000) }
        val (t, s) = assertNotNull(steps(p, 902_000, 990_000, route = busy))
        assertEquals(932_000L, t)
        assertEquals(CoachPrompter.PendingStep.Open(q), s)
    }

    @Test
    fun `an open prompt gives way to off route quietly and nothing open is nothing`() {
        val p = CoachPrompter()
        assertNull(p.giveWay(900_000))
        val q = open(p, at = 900_000)
        val a = assertNotNull(p.giveWay(q.openedAtMs + 3_000))
        assertTrue(a.quiet)
        assertNull(a.spoken)
        assertEquals(PromptChoice.hold, a.choice)
        assertEquals(PromptSource.timeout, a.source)
        assertNull(p.open)
        assertEquals(1, p.prompts)
    }

    @Test
    fun `an input just before the timeout beats it - a waiting single press is an answer not a hold`() {
        val p = CoachPrompter()
        val q = open(p)
        assertNull(p.headsetPress(q.openedAtMs + 7_800))
        val a = assertNotNull(p.tick(q.openedAtMs + 8_000))
        assertEquals(PromptSource.headset, a.source)
        assertEquals(PromptChoice.push, a.choice)
        // A tap just before the window ends answers; the timeout then has nothing left to resolve.
        val t = CoachPrompter()
        val r = open(t)
        assertEquals(PromptChoice.hold, t.answer(r.id, 1, PromptSource.tap, r.openedAtMs + 7_999)!!.choice)
        assertNull(t.tick(r.openedAtMs + 8_000))
        assertNull(t.open)
    }

    // ---- headset keys ----

    @Test
    fun `MEDIA_NEXT from a Bluetooth earbud double tap is the second option at once`() {
        assertEquals(1, HeadsetKeys.answerFor(HeadsetKeys.MEDIA_NEXT))
        assertEquals(0, HeadsetKeys.answerFor(HeadsetKeys.MEDIA_PREVIOUS))
        for (k in listOf(HeadsetKeys.HEADSETHOOK, HeadsetKeys.MEDIA_PLAY_PAUSE, HeadsetKeys.MEDIA_PLAY, HeadsetKeys.MEDIA_PAUSE)) {
            assertEquals(HeadsetKeys.COUNT, HeadsetKeys.answerFor(k), "$k is a counted press")
        }
        assertNull(HeadsetKeys.answerFor(24), "volume up is not a headset key")
        assertNull(HeadsetKeys.answerFor(0))
        // The real Android codes.
        assertEquals(87, HeadsetKeys.MEDIA_NEXT)
        assertEquals(85, HeadsetKeys.MEDIA_PLAY_PAUSE)
        assertEquals(79, HeadsetKeys.HEADSETHOOK)
    }

    @Test
    fun `an earbud NEXT answers the second option and PREVIOUS the first`() {
        val p = CoachPrompter()
        val q = open(p)
        val next = assertNotNull(p.headsetOption(1, q.openedAtMs + 2_000))
        assertEquals(PromptChoice.hold, next.choice)
        assertEquals(PromptSource.headset, next.source)
        val r = CoachPrompter()
        val q2 = open(r)
        assertEquals(PromptChoice.push, r.headsetOption(0, q2.openedAtMs + 2_000)!!.choice)
        assertNull(CoachPrompter().headsetOption(1, 1_000), "no prompt open")
        assertNull(p.headsetOption(1, q.openedAtMs + 3_000), "already answered")
    }

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
    fun `the prompter keeps the effect of the last push or ease - a between reps one lasts a rep`() {
        val p = CoachPrompter(distanceGate = false)
        val a = assertNotNull(p.atRepEnd(2, 8, 600_000, 2_000.0))
        p.opened(a, 2_000.0)
        p.startWindow(600_000)
        p.answer(a.id, 0, PromptSource.tap, 602_000)
        assertEquals(PromptEffect.PUSH.copy(oneRep = true), p.effect)
        // A distance run's push stays for the rest of the run, a hold or a timeout keeps it.
        val q = CoachPrompter()
        val b = open(q)
        q.answer(b.id, 0, PromptSource.tap, b.openedAtMs + 1_000)
        assertEquals(PromptEffect.PUSH, q.effect)
        val c = assertNotNull(q.atKm(facts(6, gapMs = -30_000), 2_000_000, 6_002.0))
        q.opened(c, 6_002.0)
        q.startWindow(2_000_000)
        q.tick(2_008_000)
        assertEquals(PromptEffect.PUSH, q.effect, "hold by timeout keeps the push")
    }

    // After a choice the cue stream follows it (the voice coach only; a plan's own target).

    private val target = 300.0

    private fun coach() = VoiceCoach(VoiceCoach.Config(true, targetPaceSecPerKm = target))

    private fun VoiceCoach.run(toS: Int, pace: Double): List<Pair<Int, String>> = (0..toS).mapNotNull { s ->
        tick(VoiceCoach.Input(s * 1_000L, 0, s * 1_000L, pace, null, null, 0))?.let { s to it.text }
    }

    private fun answered(effect: PromptEffect, atPace: Double? = null, target: Double? = this.target): VoiceCoach {
        val c = VoiceCoach(VoiceCoach.Config(true, targetPaceSecPerKm = target))
        if (atPace != null) (0..20).forEach { s -> c.tick(VoiceCoach.Input(s * 1_000L, 0, s * 1_000L, atPace, null, null, 0)) }
        c.applyEffect(effect)
        return c
    }

    private fun VoiceCoach.stream(fromS: Int, toS: Int, pace: Double): List<Pair<Int, String>> = (fromS..toS).mapNotNull { s ->
        tick(VoiceCoach.Input(s * 1_000L, 0, s * 1_000L, pace, null, null, 0))?.let { s to it.text }
    }

    @Test
    fun `after a push the same pace is slow against the tighter target and checks come twice as often`() {
        assertEquals(listOf(30 to "On pace"), coach().run(30, 300.0))
        val c = coach()
        assertEquals(PromptEffect.PUSH, c.applyEffect(PromptEffect.PUSH))
        assertEquals(listOf(30 to "Pick it up, 9 seconds slow", 60 to "Pick it up, 9 seconds slow", 90 to "Pick it up, 9 seconds slow"), c.run(100, 300.0))
    }

    @Test
    fun `a push is not applied to a runner already far off the target - no tighter target to scold them with`() {
        // 40 s/km slow when they answer: the push is dropped and the stream is the usual one line a minute.
        val c = VoiceCoach(VoiceCoach.Config(true, targetPaceSecPerKm = target))
        (0..20).forEach { s -> c.tick(VoiceCoach.Input(s * 1_000L, 0, s * 1_000L, 340.0, null, null, 0)) }
        assertEquals(PromptEffect.NONE, c.applyEffect(PromptEffect.PUSH))
        val said = c.stream(21, 120, 340.0).map { it.second }
        assertTrue(said.isNotEmpty() && said.all { it == "Pick it up, 40 seconds slow" }, "$said")
        assertTrue(said.size <= 2, "once a minute at most, never every 30 s: $said")
        // Within reach of the target (6 s/km slow) the same push does apply.
        val near = VoiceCoach(VoiceCoach.Config(true, targetPaceSecPerKm = target))
        (0..20).forEach { s -> near.tick(VoiceCoach.Input(s * 1_000L, 0, s * 1_000L, 306.0, null, null, 0)) }
        assertEquals(PromptEffect.PUSH, near.applyEffect(PromptEffect.PUSH))
    }

    @Test
    fun `after an ease off there is no Pick it up for the rest of the run`() {
        val c = coach()
        assertEquals(PromptEffect.EASE, c.applyEffect(PromptEffect.EASE))
        // 308 is slow against 300 but on pace against the eased 312; 340 is slow against both.
        assertEquals(listOf(30 to "On pace"), c.run(30, 308.0))
        val slow = answered(PromptEffect.EASE)
        assertEquals(emptyList(), slow.stream(0, 300, 340.0), "never scolds after an ease off")
        // Fast still gets its line: calmer, not silent.
        val fast = answered(PromptEffect.EASE)
        assertEquals(listOf(30 to "Ease off, 32 seconds fast"), fast.stream(0, 30, 280.0))
    }

    @Test
    fun `an answer never starts pace checks on a run with no target of its own`() {
        // A Free chase run: no plan target. Push and ease off change nothing in the stream, ever.
        for (e in listOf(PromptEffect.PUSH, PromptEffect.EASE)) {
            val c = VoiceCoach(VoiceCoach.Config(true, targetPaceSecPerKm = null))
            assertEquals(PromptEffect.NONE, c.applyEffect(e))
            assertEquals(emptyList(), c.stream(0, 300, 352.0))
            assertEquals(emptyList(), c.stream(301, 600, 290.0))
        }
    }

    @Test
    fun `a between reps answer lasts one rep and the next rep is back on the plan target`() {
        val c = VoiceCoach(VoiceCoach.Config(true, targetPaceSecPerKm = target))
        assertEquals(PromptEffect.PUSH.copy(oneRep = true), c.applyEffect(PromptEffect.PUSH.copy(oneRep = true)))
        // The next rep (segment 1): tighter target, 9 s slow at 300.
        val rep1 = (0..30).mapNotNull { s ->
            c.tick(VoiceCoach.Input(s * 1_000L, 1, s * 1_000L, 300.0, null, null, 0))?.let { s to it.text }
        }
        assertEquals(listOf(30 to "Pick it up, 9 seconds slow"), rep1)
        // The rep after (segment 2): back on 300, so 300 is on pace.
        val rep2 = (0..30).mapNotNull { s ->
            c.tick(VoiceCoach.Input(s * 1_000L, 2, s * 1_000L, 300.0, null, null, 0))?.let { s to it.text }
        }
        assertEquals(listOf(30 to "On pace"), rep2)
    }

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
        // A between-reps answer lasted one rep: after a kill it is gone.
        val rep = JournalLine.PromptResolved(5, 6, 2, "betweenReps", 2, listOf("push", "hold"), "push", "tap", 1, 2)
        assertEquals(PromptEffect.NONE, CoachPrompter(CoachPrompter.restore(listOf(rep))).effect)
        // The next prompt id does not repeat, and the last-2-km question is not asked again.
        assertNull(back.atKm(facts(4, goal = 5_000.0), 1_500_000, 4_050.0))
        assertTrue(line is JournalLine.PromptResolved)
    }
    @Test
    fun `a goal runner who is behind all the way is asked once about it and then at the last 2 km`() {
        // 8 km goal at 5:52 against a 5:14 target: the gap grows by about 38 s every km.
        val p = CoachPrompter()
        val asked = mutableListOf<PromptKind>()
        for (k in 2..6) {
            val f = facts(k, goal = 8_000.0, behind = k * 38_000L)
            val q = p.atKm(f, k * 352_000L, k * 1_000.0 + 2)
            if (q != null) {
                asked += q.kind
                p.opened(q, k * 1_000.0 + 2)
                p.answer(q.id, 0, PromptSource.tap, q.openedAtMs + 2_000) // push
            }
        }
        assertEquals(listOf(PromptKind.behindTarget, PromptKind.last2k), asked)
    }
    @Test
    fun `after an ease off the falling behind question is not asked again - and not twice anyway`() {
        val p = CoachPrompter()
        val a = assertNotNull(fallingBehind(p))
        p.opened(a, 3_002.0)
        assertEquals(PromptChoice.ease, p.answer(a.id, 1, PromptSource.tap, a.openedAtMs + 3_000)!!.choice)
        assertNull(p.atKm(facts(5, goal = 10_000.0, behind = 90_000), 1_800_000, 5_002.0))
        // A restore keeps both: it was asked, and they eased.
        val line = JournalLine.PromptResolved(903_000, 1, a.id, "behindTarget", 3, listOf("push", "ease"), "ease", "tap", 900_000, 903_000)
        val back = CoachPrompter(CoachPrompter.restore(listOf(line)))
        assertNull(back.atKm(facts(4, goal = 10_000.0, behind = 50_000), 1_300_000, 5_002.0))
        // Ahead of the PB can still ask.
        assertNotNull(p.atKm(facts(5, gapMs = -20_000), 1_800_000, 5_002.0))
    }

    @Test
    fun `a push answer to a behind prompt does not allow a second behind prompt`() {
        val p = CoachPrompter()
        val a = assertNotNull(fallingBehind(p))
        p.opened(a, 3_002.0)
        p.answer(a.id, 0, PromptSource.tap, a.openedAtMs + 2_000)
        assertNull(p.atKm(facts(6, goal = 10_000.0, behind = 120_000), 2_400_000, 6_002.0))
        assertNull(p.atKm(facts(7, goal = 10_000.0, behind = 160_000), 2_800_000, 7_002.0))
    }

    // ---- a goal run with a target time names it (26-Oct goal-run voice) ----

    private val t2430 = 1_470_000L

    @Test
    fun `last 2 km of a goal with a time names the target the margin and its trend and says what each button does`() {
        val p = CoachPrompter()
        assertNull(km(p, facts(2, goal = 5_000.0, behind = -20_000, goalMs = t2430)))
        val q = assertNotNull(km(p, facts(3, goal = 5_000.0, behind = -12_000, goalMs = t2430)))
        assertEquals(PromptKind.last2k, q.kind)
        assertEquals("2 k to go, 12 seconds under 24:30, shrinking. Push to bank more, or hold?", q.text)
        assertEquals(listOf(PromptChoice.push, PromptChoice.hold), q.options)
        assertFalse(q.text.contains("best"), "the reference is the goal time, not the PB")
    }

    @Test
    fun `an ahead runner is never told to push for under the time he is already under`() {
        val p = CoachPrompter()
        assertNull(km(p, facts(2, goal = 5_000.0, behind = -10_000, goalMs = t2430)))
        val q = assertNotNull(km(p, facts(3, goal = 5_000.0, behind = -14_000, goalMs = t2430)))
        assertEquals("2 k to go, 14 seconds under 24:30. Push to bank more, or hold?", q.text)
    }

    @Test
    fun `every goal-time prompt fits 16 words at its longest`() {
        val longest = 5_279_000L
        val p = CoachPrompter()
        assertNull(km(p, facts(4, goal = 7_500.0, behind = -130_000, goalMs = longest)))
        val ahead = assertNotNull(km(p, facts(5, goal = 7_500.0, behind = -119_000, goalMs = longest)))
        assertEquals("2.5 k to go, 1 minute 59 under 1:27:59, shrinking. Push to bank more, or hold?", ahead.text)
        assertTrue(CueComposer.words(ahead.text) <= 16, ahead.text)
        val q = CoachPrompter()
        assertNull(km(q, facts(2, goal = 10_000.0, behind = 10_000, goalMs = longest)))
        val behind = assertNotNull(km(q, facts(3, goal = 10_000.0, behind = 119_000, goalMs = longest)))
        assertTrue(CueComposer.words(behind.text) <= 16, behind.text)
    }

    @Test
    fun `last 2 km of a goal with a time before any trend leaves the trend out and level reads as on pace`() {
        assertEquals(
            "2 k to go, 8 seconds over 24:30. Push to get under it, or hold?",
            km(CoachPrompter(), facts(3, goal = 5_000.0, behind = 8_000, goalMs = t2430))!!.text,
        )
        assertEquals(
            "2 k to go, level with 24:30. Push to get under it, or hold?",
            km(CoachPrompter(), facts(3, goal = 5_000.0, behind = 1_000, goalMs = t2430))!!.text,
        )
    }

    @Test
    fun `falling behind a goal time names it and never the target`() {
        val p = CoachPrompter()
        assertNull(km(p, facts(2, goal = 10_000.0, behind = 10_000, goalMs = t2430)))
        val q = assertNotNull(km(p, facts(3, goal = 10_000.0, behind = 30_000, goalMs = t2430)))
        assertEquals(PromptKind.behindTarget, q.kind)
        assertEquals("30 seconds behind 24:30, slipping. Push to win it back, or ease off?", q.text)
        assertEquals(listOf(PromptChoice.push, PromptChoice.ease), q.options)
    }

    @Test
    fun `no goal time or a distrusted km keeps the old wording`() {
        assertEquals("2 k to go. Push or hold?", km(CoachPrompter(), facts(3, goal = 5_000.0, behind = 8_000))!!.text)
        assertEquals("2 k to go. Push or hold?", km(CoachPrompter(), facts(3, goal = 5_000.0, behind = null, goalMs = t2430))!!.text)
    }

    @Test
    fun `a Steady goal run names the goal time in the last 2 km but is never asked the falling-behind nag`() {
        val q = assertNotNull(km(CoachPrompter(), facts(3, goal = 5_000.0, behind = 8_000, chase = false, goalMs = t2430)))
        assertTrue(q.text.contains("24:30"), q.text)
        val p = CoachPrompter()
        assertNull(km(p, facts(2, goal = 10_000.0, behind = 10_000, chase = false, goalMs = t2430)))
        assertNull(km(p, facts(3, goal = 10_000.0, behind = 30_000, chase = false, goalMs = t2430)))
    }

    @Test
    fun `level but slipping is said in the last 2 km prompt`() {
        val p = CoachPrompter()
        assertNull(km(p, facts(2, goal = 5_000.0, behind = -4_000, goalMs = t2430)))
        val q = assertNotNull(km(p, facts(3, goal = 5_000.0, behind = 1_000, goalMs = t2430)))
        assertEquals("2 k to go, level with 24:30, slipping. Push to get under it, or hold?", q.text)
    }
}
