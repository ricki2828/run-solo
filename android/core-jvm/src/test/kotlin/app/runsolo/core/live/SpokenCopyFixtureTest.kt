package app.runsolo.core.live

import app.runsolo.core.json.Json
import app.runsolo.core.record.CueWords
import java.io.File
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

/** The spoken copy the engine and core-jvm share (`fixtures/phase4/spoken_copy.json`, #79 review). */
class SpokenCopyFixtureTest {
    private val fx: Map<String, Any?> = Json.parseObject(File("../../packages/run_engine/test/fixtures/phase4/spoken_copy.json").readText())

    @Test
    fun `gaps of a minute or more are said in minutes and seconds`() {
        @Suppress("UNCHECKED_CAST")
        val gaps = fx["gaps"] as List<List<Any?>>
        assertTrue(gaps.isNotEmpty())
        for (g in gaps) assertEquals(g[1], CueWords.gap((g[0] as Number).toLong()), "$g")
    }

    @Test
    fun `the engine's fast-start nudge fits its own follow-up line`() {
        @Suppress("UNCHECKED_CAST")
        val lines = (fx["fastStart"] as Map<String, Any?>).values.map { it as String }
        assertTrue(lines.isNotEmpty())
        for (l in lines) {
            assertTrue(CueComposer.words(l) <= CueComposer.MAX_WORDS, "${CueComposer.words(l)} words: $l")
            assertFalse(l.contains('—'), l)
        }
    }

    @Test
    fun `the T4 replays race the engine's current fast-start line`() {
        @Suppress("UNCHECKED_CAST")
        val lines = fx["fastStart"] as Map<String, Any?>
        assertEquals(lines["5K"], app.runsolo.core.replay.ReplayScenarios.T4.FAST_START_5K)
    }
}
