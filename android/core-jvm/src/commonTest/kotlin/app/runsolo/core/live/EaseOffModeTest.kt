package app.runsolo.core.live

import app.runsolo.core.journal.JournalCodec
import app.runsolo.core.journal.JournalLine
import app.runsolo.core.model.CueKind
import app.runsolo.core.model.LiveBoard
import app.runsolo.core.model.LiveBoardKind
import app.runsolo.core.model.LiveContext
import app.runsolo.core.model.LiveTarget
import app.runsolo.core.model.Phase
import app.runsolo.core.model.RunMode
import app.runsolo.core.model.SessionSpec
import app.runsolo.core.record.CueWords
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

/**
 * Ease off on a goal run (28-Oct): replays a whole 8 km goal run through the same pieces the recorder uses (the km cue's
 * projection and chase, the prompter, the voice coach) and scans every line said after the ease off for any word of a
 * target, goal or PB comparison.
 */
class EaseOffModeTest {
    private val spec = SessionSpec.goalDistance(8_000, "8 km")
    private val bottoms = listOf(114.0, 133.0, 152.0, 171.0)

    // 294 s/km target; a board whose PB splits (290 s/km) would give "off your best" lines if the chase were not silent.
    private fun ctx() = LiveContext(
        boards = listOf(
            LiveBoard("goal:d8000", "8 km", LiveBoardKind.distance, 8_000.0, emptyList(), pbSplitsMs = List(10) { (it + 1) * 290_000L }, pbSplitsLabel = "10K"),
        ),
        target = LiveTarget(8_000.0, 2_352_000, predicted = true),
        coachingMuted = false, builtAtMs = 0, engineVersion = 1, coachChoice = "chase",
    )

    /** Any word that compares with a target, a goal, a best or a margin. */
    private val gapWords = Regex("(?i)\\b(target|goal|behind|ahead|best|pb|off|over|under|slipping|closing|holding|margin|level|chase|chasing|pick it up|ease)\\b")

    private class Said(val t: Int, val text: String, val afterEase: Boolean)

    /** One run, second by second: 310 s/km for the first km, then 330, then 350 from km 5; HR into zone 3 at 700 s. */
    private inner class Sim(val behindAnswer: Int) {
        var coach = LiveCoach(ctx(), RunMode.intervals, spec)
        var prompter = CoachPrompter()
        var voice = newVoice()
        val journal = ArrayList<JournalLine.PromptResolved>()
        val said = ArrayList<Said>()
        val prompts = ArrayList<Prompt>()
        var d = 0.0
        var t = 0

        private fun newVoice() = VoiceCoach(VoiceCoach.Config(true, targetPaceSecPerKm = 294.0, zoneBottomsBpm = bottoms))

        fun say(text: String?, after: Boolean = coach.easeMode) {
            if (text != null) said.add(Said(t, text, after))
        }

        private fun pace() = if (d < 1_000) 310.0 else if (d < 5_000) 330.0 else 350.0

        fun run(toS: Int) {
            while (t < toS) {
                t++
                val prevD = d
                d += 1_000.0 / pace()
                val active = t * 1_000L
                if (d.toInt() / 1_000 > prevD.toInt() / 1_000) kmCue(d.toInt() / 1_000, active)
                if (coach.easeMode) voice.enterEase()
                val line = voice.tick(
                    VoiceCoach.Input(
                        t = active, segment = 0, segmentActiveMs = active, paceSecPerKm = pace(),
                        hr = if (t < 700) 120.0 else 140.0, msToPhaseEnd = null, busyUntil = 0,
                        goal = coach.goalProgress(d, active), zoneCues = true, position = VoiceCoach.Position(d, active),
                    ),
                )
                say(line?.text)
            }
        }

        private fun kmCue(km: Int, active: Long) {
            val projected = active.toDouble() / km * 8
            val fire = coach.atCue(CueKind.projection, km, projected, Phase.work, 0, active, null)
            val chase = coach.chaseAtCue(CueKind.projection, km, active)
            val base = CueWords.text(CueKind.projection, projected, spec, Phase.work, 1, 0, km, coach = true, easeProjection = coach.easeMode)
            say(fire?.takeIf { it.speak }?.base ?: base)
            say(chase?.text ?: fire?.takeIf { it.speak }?.text)
            val facts = coach.takeKmFacts() ?: return
            val p = prompter.atKm(facts, active, d) ?: return
            prompts.add(p)
            prompter.opened(p, d)
            say(p.text)
            val a = assertNotNull(prompter.answer(p.id, behindAnswer, PromptSource.tap, active + 3_000))
            journal.add(CoachPrompter.line(a, 1, active))
            // What RecordingSession.resolvePrompt does: the ease off at the falling-behind question enters the mode.
            if (a.choice == PromptChoice.ease && a.prompt.kind == PromptKind.behindTarget) coach.enterEase()
            say(a.spoken, after = false) // "Easing off." is the acknowledgement, said as the mode begins
        }

        /** A kill and restore: every piece is rebuilt, the mode comes back from the journal lines (through the codec). */
        fun killAndRestore() {
            val lines = journal.map { JournalCodec.decode(JournalCodec.encode(it)) as JournalLine.PromptResolved }
            coach = LiveCoach(ctx(), RunMode.intervals, spec).also {
                it.restoreEase(CoachPrompter.easedOffGoal(lines))
                it.resumeAt(d)
            }
            prompter = CoachPrompter(CoachPrompter.restore(lines))
            voice = newVoice()
        }
    }

    @Test
    fun `without an ease off the same run does speak the gaps - the scan has teeth`() {
        val s = Sim(behindAnswer = 0) // push
        s.run(2_600)
        assertTrue(s.said.any { gapWords.containsMatchIn(it.text) }, "${s.said.map { it.text }}")
    }

    @Test
    fun `after an ease off a whole run says no target goal or PB word`() {
        val s = Sim(behindAnswer = 1)
        s.run(2_600)
        val ask = s.prompts.first()
        assertEquals(PromptKind.behindTarget, ask.kind)
        assertEquals("Keep chasing", ask.buttonLabels[0])
        assertEquals("Ease off", ask.buttonLabels[1])
        assertEquals(1, s.prompts.size, "one question only: no last-2-km prompt after the ease off")
        val after = s.said.filter { it.afterEase }
        assertTrue(after.isNotEmpty())
        assertTrue(after.none { gapWords.containsMatchIn(it.text) }, "${after.map { it.text }}")
    }

    @Test
    fun `after an ease off every km says the projected finish plainly`() {
        val s = Sim(behindAnswer = 1)
        s.run(2_600)
        val projections = s.said.filter { it.afterEase && it.text.startsWith("On track for about ") }
        // Km 3 to 7 (the ease off was at km 2); 8 km at 330 to 350 s/km is 44 to 47 minutes.
        assertEquals(5, projections.size, "${s.said.map { it.text }}")
        projections.forEach { assertTrue(Regex("On track for about \\d+ minutes").matches(it.text), it.text) }
    }

    @Test
    fun `after an ease off it is an easy run - zone 3 is held to zone 2 and a clear pace change is still said`() {
        val s = Sim(behindAnswer = 1)
        s.run(2_600)
        val after = s.said.filter { it.afterEase }.map { it.text }
        // The run is an easy run now: zone 3 for a minute is said once as "keep it in zone 2", not as a zone-up line.
        assertTrue("Heart rate in zone 3. Keep it in zone 2." in after, "$after")
        assertTrue("Heart rate up to zone 3." !in after, "$after")
        // 330 s/km before the ease off was judged at km 2 (about 330): the move to 350 at km 5 is 20 s a km slower, once.
        assertEquals(listOf("Slowed by about 20 seconds a km."), after.filter { it.startsWith("Slowed") || it.startsWith("Sped") }, "$after")
    }

    @Test
    fun `a kill and restore after the ease off keeps the mode for the rest of the run`() {
        val s = Sim(behindAnswer = 1)
        s.run(1_200) // past the ease off at km 2, into km 3
        assertTrue(s.coach.easeMode)
        s.killAndRestore()
        assertTrue(s.coach.easeMode)
        assertNull(s.coach.goalTarget)
        s.run(2_600)
        val after = s.said.filter { it.t > 1_200 }
        assertTrue(after.isNotEmpty())
        assertTrue(after.none { gapWords.containsMatchIn(it.text) }, "${after.map { it.text }}")
        assertTrue(after.any { it.text.startsWith("On track for about ") }, "${after.map { it.text }}")
        assertEquals(1, s.prompts.size, "no prompt after the restore")
    }

    @Test
    fun `a restore of a run that never eased keeps the goal talk`() {
        val s = Sim(behindAnswer = 0)
        s.run(1_200)
        s.killAndRestore()
        assertEquals(false, s.coach.easeMode)
        assertNotNull(s.coach.goalTarget)
    }
}
