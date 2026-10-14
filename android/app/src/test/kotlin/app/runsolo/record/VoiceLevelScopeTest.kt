package app.runsolo.record

import android.content.Context
import app.runsolo.core.fs.JvmFileSystem
import app.runsolo.core.live.CheckInMetric
import app.runsolo.core.live.CheckInPlan
import app.runsolo.core.live.VoiceLevel
import app.runsolo.core.model.RunMode
import app.runsolo.core.model.Units
import app.runsolo.core.run.RunPaths
import org.junit.Assert.assertEquals
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.annotation.Config

/** Voice detail is for Free and Trail runs: a Laps (or plan) run stays on Everything, so its coaching lines are not held to the budget. */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34])
class VoiceLevelScopeTest {
    private val context: Context = RuntimeEnvironment.getApplication()
    private val fs = JvmFileSystem(context.filesDir.toPath())

    private fun levelOf(mode: RunMode, id: String, level: VoiceLevel): VoiceLevel {
        fs.mkdirs(RunPaths.RUNS_DIR)
        val s = RecordingSession(context, id, mode, null, Units.km, null, volumeKeyLaps = false)
        s.checkIn = CheckInPlan(CheckInMetric.DEFAULT, null, level)
        return s.voiceLevel
    }

    @Test
    fun `free and trail take the chosen level`() {
        assertEquals(VoiceLevel.minimal, levelOf(RunMode.free, "vl-free", VoiceLevel.minimal))
        assertEquals(VoiceLevel.coach, levelOf(RunMode.trail, "vl-trail", VoiceLevel.coach))
    }

    @Test
    fun `laps stays on everything whatever the voice detail`() {
        assertEquals(VoiceLevel.everything, levelOf(RunMode.laps, "vl-laps", VoiceLevel.minimal))
        assertEquals(VoiceLevel.everything, levelOf(RunMode.laps, "vl-laps2", VoiceLevel.coach))
    }
}
