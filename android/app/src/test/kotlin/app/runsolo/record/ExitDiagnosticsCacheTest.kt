package app.runsolo.record

import android.content.Context
import app.runsolo.platform.ExitDiagnosis
import app.runsolo.platform.ExitReason
import org.junit.Assert.assertEquals
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.annotation.Config

/** W11: the OS-kill verdict must outlive `noteStopped` so run detail can show it after the run is finalised. */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34])
class ExitDiagnosticsCacheTest {
    private val context: Context = RuntimeEnvironment.getApplication()

    @Test
    fun `cached diagnosis survives noteStopped and round-trips every field`() {
        ExitDiagnostics.noteStart(context, "r1", 1_000)
        val d = ExitDiagnosis(runId = "r1", reason = ExitReason.OS_KILLED, timestampMs = 5_000, description = "sleeping apps", manufacturer = "samsung")
        ExitDiagnostics.cache(context, d)
        ExitDiagnostics.noteStopped(context, "r1")
        assertEquals(d, ExitDiagnostics.diagnose(context, "r1"))
        // No description → null, not "".
        ExitDiagnostics.cache(context, d.copy(runId = "r2", description = null))
        assertEquals(null, ExitDiagnostics.diagnose(context, "r2").description)
    }

    @Test
    fun `without a cache or anchor the answer is none`() {
        assertEquals(ExitReason.NONE, ExitDiagnostics.diagnose(context, "unknown").reason)
    }

    @Test
    fun `the cache is bounded - oldest evicted`() {
        for (i in 0 until 70) {
            ExitDiagnostics.cache(context, ExitDiagnosis(runId = "c$i", reason = ExitReason.CRASH, timestampMs = i.toLong(), description = null, manufacturer = "x"))
        }
        assertEquals(ExitReason.NONE, ExitDiagnostics.diagnose(context, "c0").reason)
        assertEquals(ExitReason.CRASH, ExitDiagnostics.diagnose(context, "c69").reason)
    }
}
