package app.runsolo.core.contract

import app.runsolo.core.journal.JournalLine
import app.runsolo.core.live.CueComposer
import app.runsolo.core.replay.ReplayScenarios
import java.io.File
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

/** Phase 4 T4: the replay transcripts are the generator's, fit the budget, and a kill never repeats a compare or nudge. */
class TranscriptFixtureTest {
    private fun run(kind: String, kill: TranscriptFixture.Kill? = null) =
        TranscriptFixture.Shell(ReplayScenarios.create(kind)!!).also { it.run(kill) }

    @Test
    fun `checked-in transcripts match the generator byte for byte, one per T4 kind`() {
        val all = TranscriptFixture.all()
        assertEquals(ReplayScenarios.T4_KINDS, all.keys.toList())
        for ((kind, json) in all) {
            val file = File(TranscriptFixture.DIR, "$kind.json")
            assertTrue(file.exists(), "missing ${file.path}; regenerate with RegenerateFixturesKt")
            assertEquals(json + "\n", file.readText(), "$kind drifted; regenerate")
        }
        assertEquals(all.size, File(TranscriptFixture.DIR).listFiles()!!.size, "a transcript with no kind")
    }

    @Test
    fun `every T4 kind speaks, compares unless a goal, every line fits 16 words, no em dashes, in time order`() {
        for (kind in ReplayScenarios.T4_KINDS) {
            val s = run(kind)
            assertTrue(s.said.isNotEmpty(), kind)
            // Goals have no live compare yet (the goal-compare PR adds it); every other T4 kind does.
            if (!kind.startsWith("t4-goal-")) assertTrue(s.spokenExtras.any { it.key.startsWith("compare:") }, "$kind: no compare spoken")
            for (l in s.said) {
                assertTrue(CueComposer.words(l.text) <= CueComposer.MAX_WORDS, "$kind: ${l.text}")
                assertFalse(l.text.contains('—'), "$kind: ${l.text}")
            }
            assertEquals(s.said.map { it.t }.sorted(), s.said.map { it.t }, kind)
        }
    }

    /**
     * BLOCK-1 across the T4 replays: kill at a fifth, two fifths... of the trace, 30 s dark. No
     * compare or nudge is spoken twice or journaled twice, and the run keeps comparing after the
     * restore whenever the uninterrupted run had a compare well after the dark span (not intervals).
     */
    @Test
    fun `restore after a kill - never repeats a compare or nudge, and keeps comparing`() {
        for (kind in ReplayScenarios.T4_KINDS) {
            val full = run(kind)
            val endT = ReplayScenarios.create(kind)!!.fixes.last().t
            for (fifth in 1..4) {
                val kill = TranscriptFixture.Kill(atMs = endT * fifth / 5 / 1_000 * 1_000, gapMs = 30_000)
                val s = run(kind, kill)
                val keys = s.spokenExtras.map { it.key }
                assertEquals(keys.distinct(), keys, "$kind killed at ${kill.atMs}: said twice")
                val journaled = s.lines.filterIsInstance<JournalLine.CueFired>().map { "${it.kind}:${it.key}#${it.index}" }
                assertEquals(journaled.distinct(), journaled, "$kind killed at ${kill.atMs}: journaled twice")
                val resumed = s.resumedAt ?: continue
                // Intervals are exempt: the rep the kill cut is unclean, and an unclean live rep ends the
                // rep compare for the rest of the session (BLOCK-2), by design.
                if (kind == "t4-400s-fade") continue
                // The dark span's metres are never counted (reanchored), so every later point comes
                // about [Kill.gapMs] later: only a compare with that much trace left after it counts.
                val laterInFull = full.spokenExtras.any { it.key.startsWith("compare:") && it.t > resumed + 120_000 && it.t + kill.gapMs + 10_000 < endT }
                if (laterInFull) {
                    assertTrue(s.spokenExtras.any { it.key.startsWith("compare:") && it.t > resumed }, "$kind killed at ${kill.atMs}: no compare after the restore")
                }
            }
        }
    }

    private fun texts(kind: String) = run(kind).said.map { it.text }

    /** Founder 26-Sep: each nudge follows its split + rank as its own line, right after it. */
    @Test
    fun `nudges follow their cue as their own line, once per run - fast start, HR drift, rep fade`() {
        for ((kind, line) in listOf(
            "t4-free-5k-fast" to ReplayScenarios.T4.FAST_START_5K,
            "t4-free-10k-fade" to ReplayScenarios.T4.HR_DRIFT,
            "t4-400s-fade" to ReplayScenarios.T4.REP_FADE,
        )) {
            val said = texts(kind)
            val i = said.indexOf(line)
            assertTrue(i > 0, "$kind: no \"$line\" in $said")
            assertFalse(said[i - 1].contains(line), "$kind: the nudge is its own line")
            assertEquals(1, said.count { it == line }, "$kind: each rule speaks once per run (#92)")
        }
        assertTrue(texts("t4-free-5k-fast")[texts("t4-free-5k-fast").indexOf(ReplayScenarios.T4.FAST_START_5K) - 1].startsWith("1 k,"), "after the km 1 split and rank")
    }

    /** #82: the last rep's compare rides the cool-down cue. */
    @Test
    fun `the last of 8 x 400 is compared on Done Cool down`() {
        val s = run("t4-400s-fade")
        assertTrue(s.spokenExtras.any { it.key == "compare:d400x8#8" }, s.said.toString())
        assertTrue(s.said.any { it.text.startsWith("Done. Cool down.") && it.text.length > "Done. Cool down.".length }, s.said.toString())
    }

    /** Lead (#78): "new best" end to end, goals and the timed 5 km; the start says the name (#83). */
    @Test
    fun `goals and the timed 5 km start with their name and end with new best`() {
        val half = texts("t4-goal-half-best")
        assertEquals("Half marathon. Go", half.first())
        assertTrue(half.any { it.matches(Regex("Half marathon done, 1:2\\d:\\d\\d, new best\\.")) }, "$half")
        val t30 = texts("t4-goal-30min-best")
        assertEquals("30 minutes. Go", t30.first())
        assertTrue(t30.any { it.matches(Regex("30 minutes done, 6\\.\\d\\d km, new best\\.")) }, "$t30")
        val event = texts("t4-5k-target")
        assertEquals("5K time trial. Go", event.first())
        assertTrue(event.last().matches(Regex("5K time trial done, \\d\\d:\\d\\d, new best\\.")), "$event")
        assertFalse(event.any { it.contains("Cool down") }, "the event stops at 5 km")
    }

    /** The replays' goal times against the engine-built goal contexts (#78's shared fixture): new best there too. */
    @Test
    fun `the replayed goal results are new bests on the engine's own goal boards too`() {
        @Suppress("UNCHECKED_CAST")
        val fx = app.runsolo.core.json.Json.parseObject(File("../../packages/run_engine/test/fixtures/phase4/goal_live_context.json").readText())
        @Suppress("UNCHECKED_CAST")
        fun ctx(name: String) = app.runsolo.core.model.LiveContext.fromJson(fx[name] as Map<String, Any?>)
        for ((kind, name) in listOf("t4-goal-half-best" to "half", "t4-goal-30min-best" to "thirtyMin")) {
            val sc = ReplayScenarios.create(kind)!!
            val g = run(kind).said.first { it.text.contains(" done, ") }
            // The reached point the replay's core recorded, asked of the engine's context.
            val end = TranscriptFixture.Shell(sc).also { it.run() }.goalEnd!!
            val reached = app.runsolo.core.live.GoalCoach(sc.spec, ctx(name)).atCue(app.runsolo.core.model.CueKind.phaseEnd, app.runsolo.core.model.Phase.cooldown, end)!!
            assertTrue(reached.newBest, "$kind on the engine's $name context: ${reached.text} (replay said ${g.text})")
        }
    }
}
