package app.runsolo.core.record

import app.runsolo.core.live.CueComposer
import app.runsolo.core.live.CueSlot
import app.runsolo.core.live.SpeechClock
import app.runsolo.core.live.TalkBudget
import app.runsolo.core.live.TalkLine
import app.runsolo.core.live.VoiceLevel
import app.runsolo.core.model.Units
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

class StartBriefingTest {
    private val nor = StartBriefing.Slots(session = "Norwegian 4 by 4", paceSecPerKm = 288.0, minutes = 30, distanceM = 6_000.0, reps = 4)

    private fun render(t: String, slots: StartBriefing.Slots = nor, units: Units = Units.km) = StartBriefing.render(t, slots, units)

    @Test
    fun `every slot is spoken in kilometres`() {
        assertEquals("Norwegian 4 by 4", render("{session}"))
        assertEquals("4 minutes 48 per kilometre", render("{pace}"))
        assertEquals("30 minutes", render("{minutes}"))
        assertEquals("6 kilometres", render("{distance}"))
        assertEquals("four reps", render("{reps}"))
    }

    @Test
    fun `every slot is spoken in miles`() {
        assertEquals("7 minutes 43 per mile", render("{pace}", units = Units.mi))
        assertEquals("3.7 miles", render("{distance}", units = Units.mi))
        assertEquals("30 minutes", render("{minutes}", units = Units.mi))
    }

    @Test
    fun `a pace under four minutes and a whole minute pace`() {
        assertEquals("3 minutes 55 per kilometre", render("{pace}", nor.copy(paceSecPerKm = 235.0)))
        assertEquals("6 minutes 18 per mile", render("{pace}", nor.copy(paceSecPerKm = 235.0), Units.mi))
        assertEquals("5 minutes per kilometre", render("{pace}", nor.copy(paceSecPerKm = 300.0)))
    }

    @Test
    fun `whole minutes and an hour`() {
        assertEquals("5 minutes", render("{minutes}", nor.copy(minutes = 5)))
        assertEquals("1 hour", render("{minutes}", nor.copy(minutes = 60)))
        assertEquals("1 hour 30 minutes", render("{minutes}", nor.copy(minutes = 90)))
    }

    @Test
    fun `reps are spoken with their noun`() {
        assertEquals("one rep", StartBriefing.repsWords(1))
        assertEquals("four reps", StartBriefing.repsWords(4))
        assertEquals("twenty reps", StartBriefing.repsWords(20))
        assertEquals("24 reps", StartBriefing.repsWords(24))
        assertNull(StartBriefing.repsWords(0))
        assertEquals("Then six reps, hard.", render("Then {reps}, hard.", nor.copy(reps = 6)))
    }

    @Test
    fun `an unknown slot rejects the template`() {
        assertNull(render("Hold {tempo}."))
        assertNull(render("Hold {PACE}."))
        assertNull(render("Hold {pace and go."))
    }

    @Test
    fun `a slot the run has no value for rejects the template`() {
        assertNull(render("{session}.", StartBriefing.Slots()))
        assertNull(render("Hold {pace}.", StartBriefing.Slots(session = "x")))
        assertNull(render("{minutes}", nor.copy(minutes = null)))
        assertNull(render("{minutes}", nor.copy(minutes = 0)))
        assertNull(render("{distance}", nor.copy(distanceM = null)))
        assertNull(render("{reps}", nor.copy(reps = 0)))
        assertNull(render("{pace}", nor.copy(paceSecPerKm = 0.0)))
        assertNull(render("{pace}", nor.copy(paceSecPerKm = Double.NaN)))
        assertNull(render("{session}", nor.copy(session = "   ")))
    }

    @Test
    fun `a template with no slots renders as it is`() {
        assertEquals("Easy day. Nice and relaxed.", render("Easy day.  Nice and relaxed. ", StartBriefing.Slots()))
        assertNull(render("   ", StartBriefing.Slots()))
    }

    @Test
    fun `the coach template wins when it renders within the cap`() {
        val line = StartBriefing.line("Hold {pace}, {reps}.", "Fallback {pace}.", nor, Units.km)
        assertEquals("Hold 4 minutes 48 per kilometre, four reps.", line)
    }

    @Test
    fun `a coach template that does not render falls to the app's own`() {
        // Unknown slot, then a slot with no value.
        assertEquals("Own 4 minutes 48 per kilometre.", StartBriefing.line("Hold {tempo}.", "Own {pace}.", nor, Units.km))
        assertEquals("Own line.", StartBriefing.line("Easy {minutes}.", "Own line.", nor.copy(minutes = null), Units.km))
    }

    @Test
    fun `over the cap once rendered falls back and never truncates`() {
        // 22 words plus a 5 word pace and a 2 word reps = 29 once spoken: one over.
        val words = List(22) { "word" }.joinToString(" ")
        val tooLong = "$words {pace} {reps}"
        val rendered = render(tooLong)!!
        assertEquals(StartBriefing.MAX_WORDS + 1, CueComposer.words(rendered))
        assertEquals("Own line.", StartBriefing.line(tooLong, "Own line.", nor, Units.km))
        // With no fallback it is not spoken at all (the caller says the usual start line): never cut short.
        assertNull(StartBriefing.line(tooLong, null, nor, Units.km))
        // One word fewer fits exactly.
        val fits = "${List(21) { "word" }.joinToString(" ")} {pace} {reps}"
        assertEquals(StartBriefing.MAX_WORDS, CueComposer.words(render(fits)!!))
        assertEquals(render(fits), StartBriefing.line(fits, "Own line.", nor, Units.km))
    }

    @Test
    fun `the cap is on the rendered text so a short template with long slots can be over`() {
        // Every slot spoken in full is 15 words; the template itself has none of its own.
        val t = "{session} {pace} {minutes} {distance} {reps}"
        assertEquals(15, CueComposer.words(render(t)!!))
        // 13 more words make exactly the cap, 14 make one over: the template word count never decides.
        val fits = "${List(13) { "word" }.joinToString(" ")} $t"
        val over = "${List(14) { "word" }.joinToString(" ")} $t"
        assertEquals(StartBriefing.MAX_WORDS, CueComposer.words(render(fits)!!))
        assertNotNull(StartBriefing.line(fits, null, nor, Units.km))
        assertNull(StartBriefing.line(over, null, nor, Units.km))
    }

    @Test
    fun `neither template means the usual start line`() {
        assertNull(StartBriefing.line(null, null, nor, Units.km))
        assertNull(StartBriefing.line("", "  ", nor, Units.km))
    }

    @Test
    fun `a session name is made safe to read aloud`() {
        assertEquals("Kastro loop", render("{session}", nor.copy(session = "Kastro 🏃 loop https://x.co")))
    }

    @Test
    fun `the start line is spoken once per run even across a new process`() {
        var stored: String? = null
        val a = StartSpoken({ stored }, { stored = it })
        assertTrue(a.claim("run-1"))
        assertFalse(a.claim("run-1"))
        // A restored session builds a new StartSpoken over the same persisted value.
        assertFalse(StartSpoken({ stored }, { stored = it }).claim("run-1"))
        assertTrue(StartSpoken({ stored }, { stored = it }).claim("run-2"))
        assertFalse(StartSpoken({ stored }, { stored = it }).claim("run-2"))
    }

    // CuePlayer.announceSummary records the briefing in the TalkBudget (never gated) and queues it on the SpeechClock;
    // the same two calls here prove what the rest of the run can say while it is being spoken.
    private fun speakBriefing(budget: TalkBudget, clock: SpeechClock, words: Int, t: Long) {
        val text = List(words) { "w" }.joinToString(" ")
        budget.record(TalkLine(CueSlot.structure, "summary:0", text), t, clock.busyUntil)
        clock.queued(t, words)
    }

    @Test
    fun `a step cue 5 s into the briefing is never dropped`() {
        for (level in VoiceLevel.entries) {
            val budget = TalkBudget(level)
            val clock = SpeechClock()
            speakBriefing(budget, clock, StartBriefing.MAX_WORDS, 0L)
            // About 10 s of speech is queued; the first step boundary lands at t = 5 s.
            assertTrue(clock.busyUntil > 5_000L)
            assertNotNull(budget.offer(TalkLine(CueSlot.structure, "step:1", "Go. Rep 1 of 4"), 5_000L, clock.busyUntil), "$level")
            assertNotNull(budget.offer(TalkLine(CueSlot.structure, "step:2", "Recover"), 5_100L, clock.busyUntil), "$level")
        }
    }

    @Test
    fun `the briefing is exempt from the talk budget but resets its last spoke clock`() {
        val budget = TalkBudget(VoiceLevel.coach)
        val clock = SpeechClock()
        // 28 words are well over the 16 word cue budget and the 30 word window with anything else: still recorded, never refused.
        speakBriefing(budget, clock, StartBriefing.MAX_WORDS, 0L)
        // The briefing ends at 28 * 375 = 10.5 s; a km line then keeps the 25 s gap after it, not before.
        assertNull(budget.offer(TalkLine(CueSlot.km, "km:1", "1 k."), 5_000L, clock.busyUntil))
        assertNull(budget.offer(TalkLine(CueSlot.km, "km:2", "1 k."), 35_000L, clock.busyUntil))
        assertNotNull(budget.offer(TalkLine(CueSlot.km, "km:3", "1 k."), 36_000L, clock.busyUntil))
    }
}
