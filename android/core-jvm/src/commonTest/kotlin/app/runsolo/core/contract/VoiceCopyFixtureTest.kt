package app.runsolo.core.contract

import app.runsolo.core.live.CueComposer
import app.runsolo.core.record.StartBriefing
import app.runsolo.core.testio.File
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

/** Phase 4 T4 voice-copy snapshot: the checked-in file is the generator's, and every line keeps the copy rules. */
class VoiceCopyFixtureTest {
    @Test
    fun `checked-in voice copy matches the generator byte for byte`() {
        val file = File(VoiceCopyFixture.FILE)
        assertTrue(file.exists(), "missing ${file.path}; regenerate with RegenerateFixturesKt")
        assertEquals(VoiceCopyFixture.render(), file.readText(), "voice copy drifted; regenerate and review the diff")
    }

    @Test
    fun `every line fits its word budget 16 a run summary 32 a briefing 40 a prompt 24 has no em dash and every id is unique`() {
        val lines = VoiceCopyFixture.lines()
        assertEquals(lines.map { it.first }.distinct(), lines.map { it.first })
        for ((id, text) in lines) {
            // A run summary is read once, at the start or the finish, not a cue: the end stats plus the verdict get 32 words.
            // The start briefing is read once too, on the rendered text: its own 40.
            val budget = when {
                id.startsWith("summary.end") -> 32
                id.startsWith("briefing.") -> StartBriefing.MAX_WORDS
                // A two-button prompt is a question on its own, not appended to a cue: the goal-time ones say what each button means.
                id.startsWith("prompt.") -> 24
                else -> CueComposer.MAX_WORDS
            }
            assertTrue(CueComposer.words(text) <= budget, "$id: $text")
            assertFalse(text.contains('—'), "$id: $text")
            assertFalse(text.isBlank(), id)
        }
    }
}
