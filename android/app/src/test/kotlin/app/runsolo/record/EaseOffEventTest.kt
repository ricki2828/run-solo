package app.runsolo.record

import android.content.Context
import android.os.Looper
import app.runsolo.core.fs.JvmFileSystem
import app.runsolo.core.live.Prompt
import app.runsolo.core.live.PromptAnswer
import app.runsolo.core.live.PromptChoice
import app.runsolo.core.live.PromptKind
import app.runsolo.core.live.PromptSource
import app.runsolo.core.model.LiveContext
import app.runsolo.core.model.LiveTarget
import app.runsolo.core.model.RunMode
import app.runsolo.core.model.SessionSpec
import app.runsolo.core.model.Units
import app.runsolo.core.run.RunPaths
import app.runsolo.platform.PigeonEventSink
import app.runsolo.platform.PromptResolvedEvent
import app.runsolo.platform.RecorderEvent
import app.runsolo.platform.RecorderEventBus
import io.flutter.plugin.common.EventChannel
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config

/** Ease off on a goal run: the resolved-prompt event says so (the app keeps it for the upload), and the status carries it. */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34])
class EaseOffEventTest {
    private val context: Context = RuntimeEnvironment.getApplication()
    private val fs = JvmFileSystem(context.filesDir.toPath())
    private val events = ArrayList<RecorderEvent>()

    @Before
    fun listen() {
        RecorderEventBus.onListen(null, PigeonEventSink(object : EventChannel.EventSink {
            override fun success(event: Any?) { events.add(event as RecorderEvent) }
            override fun error(errorCode: String, errorMessage: String?, errorDetails: Any?) {}
            override fun endOfStream() {}
        }))
    }

    @After
    fun unlisten() = RecorderEventBus.onCancel(null)

    private val context8k = LiveContext(
        boards = emptyList(), coachingMuted = false, builtAtMs = 0, engineVersion = 1,
        target = LiveTarget(distanceM = 8000.0, targetMs = 2_402_600, predicted = true),
    )

    private fun answer(kind: PromptKind, choice: PromptChoice) = PromptAnswer(
        Prompt(1, kind, 2, listOf(PromptChoice.push, PromptChoice.ease), "", 0), choice, PromptSource.tap, 100,
    )

    private fun resolved(): List<PromptResolvedEvent> {
        shadowOf(Looper.getMainLooper()).idle()
        return events.filterIsInstance<PromptResolvedEvent>()
    }

    private fun goalSession(id: String): RecordingSession {
        fs.mkdirs(RunPaths.RUNS_DIR)
        val spec = SessionSpec.goalDistance(8000, "8 km")
        val s = RecordingSession(context, id, RunMode.intervals, spec, Units.km, null, volumeKeyLaps = false, liveContext = context8k)
        s.startNew(device = "t", app = "t", tz = "UTC")
        return s
    }

    @Test
    fun `a behindTarget prompt answered ease on a goal session says eased and the status keeps it with the target`() {
        val s = goalSession("ease-1")
        try {
            assertEquals(false, s.statusNow().goalEased)
            assertEquals(2_402_600L, s.statusNow().goalTargetMs)
            s.resolvePrompt(answer(PromptKind.behindTarget, PromptChoice.ease), 100)
            val e = resolved().single()
            assertTrue(e.eased)
            assertEquals("ease", e.choice)
            // A fresh read (not the one-tick-old snapshot) sees the mode, and the target stays named.
            assertEquals(true, s.statusNow().goalEased)
            assertEquals(2_402_600L, s.statusNow().goalTargetMs)
        } finally {
            s.abortStart()
        }
    }

    @Test
    fun `a push or a hold on a goal session, or an ease at another question, is not eased`() {
        val s = goalSession("ease-2")
        try {
            s.resolvePrompt(answer(PromptKind.behindTarget, PromptChoice.push), 100)
            s.resolvePrompt(answer(PromptKind.last2k, PromptChoice.ease), 200)
            val out = resolved()
            assertEquals(2, out.size)
            assertTrue(out.none { it.eased })
            assertEquals(false, s.statusNow().goalEased)
        } finally {
            s.abortStart()
        }
    }

    @Test
    fun `a session that is not a goal run reports no goal fields`() {
        fs.mkdirs(RunPaths.RUNS_DIR)
        val s = RecordingSession(context, "ease-3", RunMode.free, null, Units.km, null, volumeKeyLaps = false)
        s.startNew(device = "t", app = "t", tz = "UTC")
        try {
            assertNull(s.statusNow().goalEased)
            assertNull(s.statusNow().goalTargetMs)
        } finally {
            s.abortStart()
        }
    }
}
