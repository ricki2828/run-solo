package app.runsolo

import android.content.Context
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34])
class DiagnosticsFilesTest {
    private val context: Context = RuntimeEnvironment.getApplication()

    @Test
    fun `a crash is appended to the shared diagnostics dir`() {
        DiagnosticsFiles.crashFile(context).delete()
        DiagnosticsFiles.appendCrash(context, "main", IllegalStateException("boom"), "0.1.0", 1_000)
        val text = DiagnosticsFiles.crashFile(context).readText()
        assertTrue(text.contains("native thread=main app=0.1.0"))
        assertTrue(text.contains("IllegalStateException: boom"))
    }

    @Test
    fun `the chained handler records then calls the previous handler`() {
        val calls = mutableListOf<String>()
        val previous = Thread.UncaughtExceptionHandler { _, e -> calls += "prev:${e.message}" }
        DiagnosticsFiles.Chained(previous) { _, e -> calls += "rec:${e.message}" }
            .uncaughtException(Thread.currentThread(), RuntimeException("x"))
        assertEquals(listOf("rec:x", "prev:x"), calls)
    }

    @Test
    fun `the file is capped - older half dropped`() {
        val file = DiagnosticsFiles.crashFile(context)
        file.parentFile!!.mkdirs()
        file.writeText((0 until 4000).joinToString("\n") { "old line $it padding padding padding" } + "\n")
        assertTrue(file.length() > DiagnosticsFiles.MAX_BYTES)
        DiagnosticsFiles.appendCrash(context, "t", RuntimeException("new"), "v", 2_000)
        assertTrue(file.length() < DiagnosticsFiles.MAX_BYTES)
        assertTrue(file.readText().contains("RuntimeException: new"))
    }

    @Test
    fun `exit tail is none without verdicts`() {
        assertEquals("(none)", DiagnosticsFiles.exitTail(context))
    }
}
