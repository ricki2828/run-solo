package app.runsolo.core.record

import app.runsolo.core.journal.JournalCodec
import app.runsolo.core.journal.JournalLine
import app.runsolo.core.journal.JournalReplay
import app.runsolo.core.model.CueKind
import app.runsolo.core.model.LapSource
import app.runsolo.core.model.Phase
import app.runsolo.core.model.RecoveryStyle
import app.runsolo.core.model.RunMode
import app.runsolo.core.model.SessionSpec
import app.runsolo.core.model.Step
import app.runsolo.core.model.StepKind
import app.runsolo.core.model.TargetKind
import app.runsolo.core.model.Units
import app.runsolo.core.run.RunFile
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

/**
 * Treadmill distance reps: REP DONE is a manual lap in a distance step (the belt gives no distance, so the step
 * never ends on its own); UNDO takes the latest one back, in the core and in the journal.
 */
class RecorderCoreRepDoneTest {
    private val t0 = 1_000_000L
    private val base = SessionSpec.norwegian4x4().copy(templateId = "custom:t", name = "t", hrBand = null)
    private fun workM(m: Int, rep: Int) = Step(StepKind.work, TargetKind.distance, m, RecoveryStyle.run, rep)
    private fun recM(m: Int, rep: Int) = Step(StepKind.recovery, TargetKind.distance, m, RecoveryStyle.jog, rep)
    private fun recS(sec: Int, rep: Int) = Step(StepKind.recovery, TargetKind.time, sec, RecoveryStyle.jog, rep)
    private val threeReps = base.copy(steps = listOf(workM(400, 1), recM(200, 1), workM(400, 2), recM(200, 2), workM(400, 3)))
    private val timedRecovery = base.copy(steps = listOf(workM(400, 1), recS(60, 1), workM(400, 2)))

    private fun started(spec: SessionSpec): RecorderCore {
        val core = RecorderCore(RunMode.intervals, spec)
        core.start(t0)
        core.tick(t0 + 1_000, 0.0)
        core.startReps(t0 + 5_000)
        return core
    }

    @Test
    fun `a distance rep on a belt does not end on its own and a tap ends it`() {
        val core = started(threeReps)
        for (i in 6..120) core.tick(t0 + i * 1_000L, 0.0)
        assertEquals(Phase.work, core.phase)
        assertEquals(1, core.repIndex)
        val (decision, out) = core.lap(LapSource.button, t0 + 121_000)
        assertEquals(RecorderCore.LapDecision.accepted, decision)
        assertEquals(1, out.filterIsInstance<RecorderCore.Output.Lap>().size)
        assertEquals(Phase.recovery, core.phase)
        assertEquals(1, core.repIndex)
    }

    @Test
    fun `undo puts the rep back and the next tap works again`() {
        val core = started(threeReps)
        core.lap(LapSource.button, t0 + 60_000)
        val lapsAfterTap = core.lapCount
        val out = core.undoLap(t0 + 62_000)
        assertNotNull(out)
        assertEquals(lapsAfterTap - 1, core.lapCount)
        assertEquals(Phase.work, core.phase)
        assertEquals(1, core.repIndex)
        assertEquals(0, core.stepIndex)
        // The rep kept its own start, so its clock is unbroken: 62 s - 5 s into it.
        assertEquals(57_000L, core.status(t0 + 62_000).phaseActiveMs)
        assertEquals(400.0, core.status(t0 + 62_000).stepRemainingM)
        val phase = out.filterIsInstance<RecorderCore.Output.PhaseChanged>().single()
        assertEquals(Phase.work, phase.phase)
        // The runner taps again, now for real, past the debounce.
        val (decision, _) = core.lap(LapSource.button, t0 + 70_000)
        assertEquals(RecorderCore.LapDecision.accepted, decision)
        assertEquals(Phase.recovery, core.phase)
    }

    @Test
    fun `only the latest tap can be taken back and only once`() {
        val core = started(threeReps)
        core.lap(LapSource.button, t0 + 60_000)
        core.lap(LapSource.button, t0 + 100_000) // the distance recovery done
        assertEquals(Phase.work, core.phase)
        assertEquals(2, core.repIndex)
        assertNotNull(core.undoLap(t0 + 101_000))
        assertEquals(Phase.recovery, core.phase)
        assertEquals(1, core.repIndex)
        assertNull(core.undoLap(t0 + 102_000), "one level of undo")
    }

    @Test
    fun `an auto lap after the tap makes the undo too late`() {
        val core = started(timedRecovery)
        core.lap(LapSource.button, t0 + 60_000)
        assertEquals(Phase.recovery, core.phase)
        // The 60 s recovery runs out on its own: the next rep starts, an auto lap.
        for (i in 61..125) core.tick(t0 + i * 1_000L, 0.0)
        assertEquals(Phase.work, core.phase)
        assertEquals(2, core.repIndex)
        assertNull(core.undoLap(t0 + 126_000))
    }

    @Test
    fun `the undo window and a pause`() {
        val core = started(threeReps)
        core.lap(LapSource.button, t0 + 60_000)
        assertNull(core.undoLap(t0 + 60_000 + RecorderCore.UNDO_WINDOW_MS + 1))
        val core2 = started(threeReps)
        core2.lap(LapSource.button, t0 + 60_000)
        core2.pause(t0 + 61_000)
        assertNull(core2.undoLap(t0 + 62_000))
        assertNull(started(threeReps).undoLap(t0 + 10_000), "nothing to undo before any lap after the warm-up")
    }

    private fun header(incline: Double?) = JournalLine.Header(0, 1_700_000_000_000, "belt", "phone", "test", "UTC", RunMode.intervals, threeReps, Units.km, incline)
    private fun replay(lines: List<JournalLine>) = JournalReplay.read(lines.joinToString("") { JournalCodec.encode(it) + "\n" }.encodeToByteArray())

    @Test
    fun `the undo line drops the lap from the replay and the restored session is in the rep`() {
        val w = 1_700_000_000_000
        val lines = listOf(
            header(1.0),
            JournalLine.Sample.noFix(1_000, w + 1_000, 140),
            JournalLine.Lap(5_000, w + 5_000, LapSource.button),
            JournalLine.Sample.noFix(9_000, w + 9_000, 160),
            JournalLine.Lap(20_000, w + 20_000, LapSource.button),
            JournalLine.LapUndo(22_000, w + 22_000),
            JournalLine.Sample.noFix(30_000, w + 30_000, 165),
        )
        val replayed = replay(lines)
        assertEquals(1, replayed.events.count { it is app.runsolo.core.journal.RunEvent.Lap })
        val restored = RecorderCore.restore(replayed, nowT = 9_000_000)
        assertEquals(Phase.work, restored.phase)
        assertEquals(1, restored.repIndex)
        val run = RunFile.fromReplay(replayed, w + 30_000)
        // The warm-up lap and the run's last lap: the mis-tap left no mark.
        assertEquals(2, run.laps.size)
        assertEquals(1.0, run.treadmillInclinePct)
    }

    @Test
    fun `a tap that stands is kept by the replay and a kill after it restores recovery`() {
        val w = 1_700_000_000_000
        val lines = listOf(
            header(1.0),
            JournalLine.Sample.noFix(1_000, w + 1_000, 140),
            JournalLine.Lap(5_000, w + 5_000, LapSource.button),
            JournalLine.Lap(60_000, w + 60_000, LapSource.button),
            JournalLine.Sample.noFix(70_000, w + 70_000, 150),
        )
        val replayed = replay(lines)
        val restored = RecorderCore.restore(replayed, nowT = 9_000_000)
        assertEquals(Phase.recovery, restored.phase)
        assertEquals(1, restored.repIndex)
        assertEquals(3, RunFile.fromReplay(replayed, w + 70_000).laps.size)
    }

    @Test
    fun `the undo line round trips`() {
        val u = JournalLine.LapUndo(6, 1_700_000_000_006)
        assertEquals(u, JournalCodec.decode(JournalCodec.encode(u)))
    }

    @Test
    fun `a belt distance step tells the runner to tap and an outdoor one does not`() {
        val belt = CueWords.text(CueKind.start, null, threeReps, Phase.work, 1, 0, treadmill = true)
        assertTrue(belt!!.contains("rep: tap when the treadmill shows it"), belt)
        assertTrue(belt.startsWith("400"), belt)
        val recovery = CueWords.text(CueKind.start, null, threeReps, Phase.recovery, 1, 1, treadmill = true)
        assertTrue(recovery!!.contains("recovery: tap when the treadmill shows it"), recovery)
        val outdoor = CueWords.text(CueKind.start, null, threeReps, Phase.work, 1, 0)
        assertTrue(!outdoor!!.contains("tap"), outdoor)
    }

    @Test
    fun `a treadmill goal ends on a tap and says so at the start`() {
        val goal = SessionSpec.goalDistance(5_000, "5K")
        val core = RecorderCore(RunMode.intervals, goal, RecorderCore.Config(volumeKeyLaps = false, treadmill = true))
        core.start(t0)
        assertEquals(Phase.work, core.phase)
        // Outdoors a lap in a goal's step marks a lap and no more.
        val outdoor = RecorderCore(RunMode.intervals, goal)
        outdoor.start(t0)
        outdoor.lap(LapSource.button, t0 + 30_000)
        assertEquals(Phase.work, outdoor.phase)
        for (i in 1..600) core.tick(t0 + i * 1_000L, 0.0)
        assertEquals(Phase.work, core.phase, "no GPS, so the goal does not end on its own")
        val (decision, _) = core.lap(LapSource.button, t0 + 601_000)
        assertEquals(RecorderCore.LapDecision.accepted, decision)
        assertEquals(Phase.cooldown, core.phase)
        assertNotNull(core.finalStepEnd)
        assertNotNull(core.undoLap(t0 + 603_000))
        assertEquals(Phase.work, core.phase)
        assertNull(core.finalStepEnd, "the undo takes the goal's end back too")
        val said = CueWords.text(CueKind.start, null, goal, Phase.work, 1, 0, treadmill = true)!!
        assertTrue(said.contains("Tap when the treadmill shows it"), said)
        assertTrue(!CueWords.text(CueKind.start, null, goal, Phase.work, 1, 0)!!.contains("Tap"))
    }
}
