package app.runsolo.core.contract

import app.runsolo.core.live.CueComposer
import java.io.File
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
    fun `every line fits 16 words, has no em dash, and every id is unique`() {
        val lines = VoiceCopyFixture.lines()
        assertEquals(lines.map { it.first }.distinct(), lines.map { it.first })
        for ((id, text) in lines) {
            assertTrue(CueComposer.words(text) <= CueComposer.MAX_WORDS, "$id: $text")
            assertFalse(text.contains('—'), "$id: $text")
            assertFalse(text.isBlank(), id)
        }
    }
}
