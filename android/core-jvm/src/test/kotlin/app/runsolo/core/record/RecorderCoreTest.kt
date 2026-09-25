package app.runsolo.core.record

import app.runsolo.core.journal.JournalCodec
import app.runsolo.core.journal.JournalLine
import app.runsolo.core.journal.JournalReplay
import app.runsolo.core.model.CueKind
import app.runsolo.core.model.CueProfile
import app.runsolo.core.model.LapSource
import app.runsolo.core.model.Phase
import app.runsolo.core.model.RecorderState
import app.runsolo.core.model.RecoveryStyle
import app.runsolo.core.model.RunMode
import app.runsolo.core.model.SessionSpec
import app.runsolo.core.model.Step
import app.runsolo.core.model.StepKind
import app.runsolo.core.model.TargetKind
import app.runsolo.core.model.Units
import app.runsolo.core.record.RecorderCore.LapDecision
import app.runsolo.core.record.RecorderCore.Output
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertNull
import kotlin.test.assertTrue

class RecorderCoreTest {
    private val preset = SessionSpec.norwegian4x4()
    private val t0 = 1_000_000L

    /** Drives the core at 1 Hz between two device times, collecting outputs. */
    private fun run(core: RecorderCore, from: Long, to: Long, stepMs: Long = 1000): List<Output> {
        val out = ArrayList<Output>()
        var t = from
        while (t <= to) {
            out.addAll(core.tick(t))
            t += stepMs
        }
        return out
    }

    private fun cues(out: List<Output>) = out.filterIsInstance<Output.Cue>().map { it.kind to it.t - t0 }
    private fun laps(out: List<Output>) = out.filterIsInstance<Output.Lap>().map { it.source to it.t - t0 }

    @Test
    fun `cue scheduler - 4 00 and 3 00 phases`() {
        assertEquals(
            listOf(CueKind.start to 0L, CueKind.halfway to 120_000L, CueKind.thirtySeconds to 210_000L, CueKind.phaseEnd to 240_000L),
            CueScheduler.forPhase(240_000).map { it.kind to it.atMs },
        )
        assertEquals(
            listOf(0L, 90_000L, 150_000L, 180_000L),
            CueScheduler.forPhase(180_000).map { it.atMs },
        )
        // A 60 s phase has no −30 s cue (it would coincide with halfway).
        assertEquals(listOf(CueKind.start, CueKind.halfway, CueKind.phaseEnd), CueScheduler.forPhase(60_000).map { it.kind })
        assertEquals(4, CueScheduler.forPhase(120_000).size) // 2:00 recovery boundary: 0, 60, 90, 120
    }

    @Test
    fun `full 4x4 - first LAP starts rep 1, auto laps at phase ends, cooldown after last recovery`() {
        val core = RecorderCore(RunMode.intervals, preset)
        core.start(t0)
        assertEquals(Phase.warmup, core.phase)
        assertTrue(run(core, t0, t0 + 60_000).isEmpty(), "warmup is untimed: no cues")
        val (d, first) = core.lap(LapSource.notification, t0 + 60_000)
        assertEquals(LapDecision.accepted, d)
        assertEquals(listOf(LapSource.notification to 60_000L), laps(first))
        assertEquals(listOf(CueKind.start to 60_000L), cues(first))
        assertEquals(Phase.work, core.phase)
        assertEquals(1, core.repIndex)

        // 4 reps = 4 work + 3 recovery phases: the last rep goes straight to cool-down.
        val total = 4 * 240_000L + 3 * 180_000L
        val out = run(core, t0 + 60_000, t0 + 60_000 + total + 5_000)
        val autoLaps = laps(out)
        assertEquals(7, autoLaps.size)
        assertTrue(autoLaps.all { it.first == LapSource.auto })
        // Lap times are exact phase boundaries, not tick times.
        assertEquals(60_000 + 240_000L, autoLaps[0].second)
        assertEquals(60_000 + 420_000L, autoLaps[1].second)
        assertEquals(60_000 + total, autoLaps[6].second)
        assertEquals(Phase.cooldown, core.phase)
        assertEquals(4, core.repIndex)
        assertEquals(8, core.lapCount)
        val c = cues(out)
        // Rep 1 work: halfway 2:00, -30 3:30, end 4:00, then recovery start.
        assertEquals(
            listOf(CueKind.halfway to 180_000L, CueKind.thirtySeconds to 270_000L, CueKind.phaseEnd to 300_000L, CueKind.start to 300_000L),
            c.take(4),
        )
        assertEquals(4 * 4 + 3 * 4 - 1, c.size) // 4 cues per timed phase, 7 phases; rep 1's start cue came with the LAP
        assertEquals(CueKind.phaseEnd, c.last().first) // the last cue is the end of rep 4, straight into cool-down
        assertTrue(run(core, t0 + 60_000 + total + 6_000, t0 + 60_000 + total + 120_000).isEmpty(), "cooldown is untimed")
        assertEquals(listOf(Output.Cue(t0 + 2_000_000, CueKind.stop)), core.stop(t0 + 2_000_000))
        assertEquals(RecorderState.finalising, core.state)
    }

    @Test
    fun `phase sequence for 1 to 6 reps - N work, N-1 recovery, then cooldown`() {
        for (reps in 1..6) {
            val p = SessionSpec.norwegian4x4(reps, 240, 180)
            val core = RecorderCore(RunMode.intervals, p)
            core.start(t0)
            val phases = ArrayList<Pair<Phase, Int>>()
            fun collect(out: List<Output>) = out.filterIsInstance<Output.PhaseChanged>().forEach { phases.add(it.phase to it.repIndex) }
            collect(core.lap(LapSource.button, t0).second)
            collect(run(core, t0, t0 + reps * 240_000L + (reps - 1) * 180_000L + 60_000L))
            val expected = ArrayList<Pair<Phase, Int>>()
            for (r in 1..reps) {
                expected.add(Phase.work to r)
                if (r < reps) expected.add(Phase.recovery to r)
            }
            expected.add(Phase.cooldown to reps)
            assertEquals(expected, phases, "reps=$reps")
            assertEquals(2 * reps, core.lapCount, "reps=$reps: the warm-up LAP plus one auto lap per timed phase end (2N-1 phases)")
            assertEquals(Phase.cooldown, core.phase)
        }
    }

    @Test
    fun `startReps - ends the warm-up like a first LAP, no-op anywhere else`() {
        val core = RecorderCore(RunMode.intervals, preset)
        assertEquals(LapDecision.ignoredIdle, core.startReps(t0).first)
        core.start(t0)
        run(core, t0, t0 + 90_000)
        val (d, out) = core.startReps(t0 + 90_000)
        assertEquals(LapDecision.accepted, d)
        assertEquals(listOf(LapSource.button to 90_000L), laps(out))
        assertEquals(listOf(CueKind.start to 90_000L), cues(out))
        assertEquals(Phase.work, core.phase)
        assertEquals(1, core.repIndex)
        assertEquals(LapDecision.ignoredNotWarmup, core.startReps(t0 + 100_000).first) // mid-rep: never a lap
        assertEquals(1, core.lapCount)
        core.pause(t0 + 110_000)
        assertEquals(LapDecision.ignoredPaused, core.startReps(t0 + 111_000).first)
        val free = RecorderCore(RunMode.laps, null)
        free.start(t0)
        assertEquals(LapDecision.ignoredNotWarmup, free.startReps(t0 + 1000).first)
    }

    @Test
    fun `double-lap guard - manual press within 5 s of an auto lap is ignored`() {
        val core = RecorderCore(RunMode.intervals, preset)
        core.start(t0)
        core.lap(LapSource.button, t0)
        run(core, t0, t0 + 240_000)
        assertEquals(Phase.recovery, core.phase)
        assertEquals(LapDecision.ignoredDoubleLap, core.lap(LapSource.button, t0 + 243_000).first)
        assertEquals(Phase.recovery, core.phase)
        assertEquals(LapDecision.accepted, core.lap(LapSource.button, t0 + 245_000).first)
        assertEquals(Phase.work, core.phase)
        assertEquals(2, core.repIndex)
    }

    @Test
    fun `debounce - two manual presses 400 ms apart count once`() {
        val core = RecorderCore(RunMode.laps, null)
        core.start(t0)
        assertEquals(LapDecision.accepted, core.lap(LapSource.volumeKey, t0 + 1000).first)
        assertEquals(LapDecision.ignoredDebounce, core.lap(LapSource.volumeKey, t0 + 1300).first)
        assertEquals(LapDecision.accepted, core.lap(LapSource.button, t0 + 1400).first)
        assertEquals(2, core.lapCount)
    }

    @Test
    fun `free mode (and cooper) ignore every lap source - no lap, no phase, no cue`() {
        for (mode in listOf(RunMode.free, RunMode.cooper)) {
            val core = RecorderCore(mode, null)
            assertTrue(core.start(t0).isEmpty())
            for (src in LapSource.values()) {
                val (d, out) = core.lap(src, t0 + 1_000)
                assertEquals(LapDecision.ignoredModeNoLaps, d, "$mode $src")
                assertTrue(out.isEmpty())
            }
            assertEquals(0, core.lapCount)
            assertTrue(run(core, t0, t0 + 600_000, 10_000).isEmpty())
            assertEquals(Phase.none, core.phase)
            assertEquals(listOf(Output.Cue(t0 + 700_000, CueKind.stop)), core.stop(t0 + 700_000))
        }
    }

    @Test
    fun `mode and session must agree`() {
        assertFailsWith<IllegalArgumentException> { RecorderCore(RunMode.intervals, null) }
        assertFailsWith<IllegalArgumentException> { RecorderCore(RunMode.laps, preset) }
        assertFailsWith<IllegalArgumentException> { RecorderCore(RunMode.free, preset) }
        assertFailsWith<IllegalArgumentException> { RecorderCore(RunMode.free, SessionSpec.FARTLEK) }
        assertFailsWith<IllegalArgumentException> { RecorderCore(RunMode.cooper, preset) }
        RecorderCore(RunMode.laps, SessionSpec.FARTLEK)
        RecorderCore(RunMode.cooper, SessionSpec.COOPER)
        RecorderCore(RunMode.cooper, null)
        assertEquals(true, RunMode.laps.volumeKeyLapsDefault)
        assertEquals(listOf(false, false, false), listOf(RunMode.intervals, RunMode.free, RunMode.cooper).map { it.volumeKeyLapsDefault })
    }

    @Test
    fun `volume keys - off by default in preset mode, on in laps mode, never re-align`() {
        val preset4 = RecorderCore(RunMode.intervals, preset)
        preset4.start(t0)
        assertEquals(LapDecision.ignoredVolumeKeyDisabled, preset4.lap(LapSource.volumeKey, t0 + 1000).first)
        assertEquals(0, preset4.lapCount)

        val optIn = RecorderCore(RunMode.intervals, preset, RecorderCore.Config(volumeKeyLaps = true))
        optIn.start(t0)
        optIn.lap(LapSource.button, t0)
        run(optIn, t0, t0 + 10_000)
        assertEquals(LapDecision.accepted, optIn.lap(LapSource.volumeKey, t0 + 10_000).first)
        assertEquals(2, optIn.lapCount)
        assertEquals(Phase.work, optIn.phase) // no re-align
        assertEquals(1, optIn.repIndex)
        assertEquals(230_000, optIn.status(t0 + 10_000).phaseRemainingMs)
    }

    @Test
    fun `manual LAP mid-phase ends it early and re-aligns`() {
        val core = RecorderCore(RunMode.intervals, preset)
        core.start(t0)
        core.lap(LapSource.button, t0)
        run(core, t0, t0 + 200_000) // 3:20 into work
        val (d, out) = core.lap(LapSource.button, t0 + 200_000)
        assertEquals(LapDecision.accepted, d)
        assertEquals(Phase.recovery, core.phase)
        assertEquals(listOf(CueKind.start to 200_000L), cues(out))
        assertEquals(180_000, core.status(t0 + 200_000).phaseRemainingMs)
        // The old work phase's remaining cues are gone.
        assertEquals(listOf(CueKind.halfway to 290_000L), cues(run(core, t0 + 201_000, t0 + 290_000)))
    }

    @Test
    fun `pause freezes the phase timer and laps are ignored while paused`() {
        val core = RecorderCore(RunMode.intervals, preset)
        core.start(t0)
        core.lap(LapSource.button, t0)
        run(core, t0, t0 + 100_000)
        core.pause(t0 + 100_000)
        assertEquals(RecorderState.paused, core.state)
        assertTrue(run(core, t0 + 100_000, t0 + 400_000).isEmpty(), "no cues while paused")
        assertEquals(LapDecision.ignoredPaused, core.lap(LapSource.button, t0 + 300_000).first)
        assertEquals(140_000, core.status(t0 + 400_000).phaseRemainingMs)
        assertEquals(400_000, core.status(t0 + 400_000).elapsedMs)
        assertEquals(100_000, core.status(t0 + 400_000).activeMs)
        core.resume(t0 + 400_000)
        val out = run(core, t0 + 400_000, t0 + 540_000)
        assertEquals(listOf(CueKind.halfway to 420_000L, CueKind.thirtySeconds to 510_000L, CueKind.phaseEnd to 540_000L, CueKind.start to 540_000L), cues(out))
    }

    @Test
    fun `late tick still lands the auto lap on the boundary`() {
        val core = RecorderCore(RunMode.intervals, preset)
        core.start(t0)
        core.lap(LapSource.button, t0)
        core.tick(t0 + 1000)
        val out = core.tick(t0 + 247_500) // the process was starved for 4 minutes
        assertEquals(listOf(LapSource.auto to 240_000L), laps(out))
        assertEquals(Phase.recovery, core.phase)
        assertEquals(172_500, core.status(t0 + 247_500).phaseRemainingMs)
    }

    @Test
    fun `laps mode has no phases and honours every manual source`() {
        val core = RecorderCore(RunMode.laps, null)
        core.start(t0)
        assertEquals(Phase.none, core.phase)
        assertTrue(run(core, t0, t0 + 3_600_000, 10_000).isEmpty())
        core.lap(LapSource.button, t0 + 1_000)
        core.lap(LapSource.notification, t0 + 2_000)
        core.lap(LapSource.volumeKey, t0 + 3_000)
        assertEquals(3, core.lapCount)
        assertEquals(0, core.status(t0 + 5000).phaseRemainingMs)
    }

    @Test
    fun `restore from a journal rebuilds phase, rep and remaining time across a gap`() {
        // Journal: start, LAP at 10 s (rep 1 work), auto-lap at 250 s (recovery), killed at 300 s;
        // dark for 60 s; gap line written at device t = 7 000 on the new boot.
        val w0 = 1_700_000_000_000L
        val d0 = 500_000L
        val lines = listOf(
            JournalLine.Header(d0, w0, "r", "d", "a", "UTC", RunMode.intervals, preset, Units.km),
            JournalLine.Lap(d0 + 10_000, w0 + 10_000, LapSource.button),
            JournalLine.Cue(d0 + 130_000, w0 + 130_000, CueKind.halfway),
            JournalLine.Lap(d0 + 250_000, w0 + 250_000, LapSource.auto),
            JournalLine.Sample(d0 + 300_000, w0 + 300_000, 0.0, 0.0, null, 5.0, null, null),
            JournalLine.Gap(7_000, w0 + 360_000, 60_000),
        )
        val replay = JournalReplay.read(lines.joinToString("") { JournalCodec.encode(it) + "\n" }.toByteArray())
        assertEquals(360_000, replay.endT)
        val core = RecorderCore.restore(replay, nowT = 7_000)
        assertEquals(RecorderState.recording, core.state)
        assertEquals(Phase.recovery, core.phase)
        assertEquals(1, core.repIndex)
        assertEquals(2, core.lapCount)
        val s = core.status(7_000)
        assertEquals(360_000, s.elapsedMs)
        assertEquals(300_000, s.activeMs) // the 60 s gap is not active time
        assertEquals(130_000, s.phaseRemainingMs) // 50 s into the 3:00 recovery
        // Halfway (1:30) is still ahead; start was already spoken and is not repeated.
        val out = run(core, 7_000, 7_000 + 130_000)
        assertEquals(listOf(CueKind.halfway to 40_000L, CueKind.thirtySeconds to 100_000L, CueKind.phaseEnd to 130_000L, CueKind.start to 130_000L), out.filterIsInstance<Output.Cue>().map { it.kind to it.t - 7_000 })
        assertEquals(Phase.work, core.phase)
        assertEquals(2, core.repIndex)
    }

    @Test
    fun `restore of a schema-1 free journal with 2 manual laps resumes as laps and accepts further laps (N2)`() {
        val w0 = 1_700_000_000_000L
        val v1Header = """{"k":"hdr","schema":1,"t":0,"w":$w0,"id":"r","device":"d","app":"a","tz":"UTC","mode":"free","preset":null,"units":"km"}"""
        val rest = listOf(
            JournalLine.Lap(5_000, w0 + 5_000, LapSource.volumeKey),
            JournalLine.Lap(9_000, w0 + 9_000, LapSource.button),
            JournalLine.Sample(10_000, w0 + 10_000, 0.0, 0.0, null, 5.0, null, null),
            JournalLine.Gap(100, w0 + 40_000, 30_000),
        ).joinToString("") { JournalCodec.encode(it) + "\n" }
        val replay = JournalReplay.read((v1Header + "\n" + rest).toByteArray())
        assertEquals(RunMode.laps, replay.header.mode)
        val core = RecorderCore.restore(replay, nowT = 100)
        assertEquals(RunMode.laps, core.mode)
        assertEquals(RecorderState.recording, core.state)
        assertEquals(2, core.lapCount)
        assertEquals(LapDecision.accepted, core.lap(LapSource.volumeKey, 2_100).first)
        assertEquals(LapDecision.accepted, core.lap(LapSource.notification, 4_100).first)
        assertEquals(4, core.lapCount)
    }

    @Test
    fun `restore of a schema-2 free journal stays free and still ignores laps`() {
        val w0 = 1_700_000_000_000L
        val lines = listOf(
            JournalLine.Header(0, w0, "r", "d", "a", "UTC", RunMode.free, null, Units.km),
            JournalLine.Sample(10_000, w0 + 10_000, 0.0, 0.0, null, 5.0, null, null),
            JournalLine.Gap(100, w0 + 40_000, 30_000),
        )
        val core = RecorderCore.restore(JournalReplay.read(lines.joinToString("") { JournalCodec.encode(it) + "\n" }.toByteArray()), nowT = 100)
        assertEquals(RunMode.free, core.mode)
        assertEquals(LapDecision.ignoredModeNoLaps, core.lap(LapSource.button, 2_100).first)
    }

    @Test
    fun `restore of a journal that ended paused resumes paused`() {
        val w0 = 1_700_000_000_000L
        val lines = listOf(
            JournalLine.Header(0, w0, "r", "d", "a", "UTC", RunMode.laps, null, Units.km),
            JournalLine.Lap(5_000, w0 + 5_000, LapSource.button),
            JournalLine.Pause(8_000, w0 + 8_000),
            JournalLine.Gap(100, w0 + 20_000, 12_000),
        )
        val replay = JournalReplay.read(lines.joinToString("") { JournalCodec.encode(it) + "\n" }.toByteArray())
        val core = RecorderCore.restore(replay, nowT = 100)
        assertEquals(RecorderState.paused, core.state)
        assertEquals(1, core.lapCount)
        assertEquals(20_000, core.status(100).elapsedMs)
        core.resume(1_100)
        assertEquals(8_000, core.status(1_100).activeMs)
    }
}

class RecorderCoreStepsTest {
    private val t0 = 1_000_000L
    private val base = SessionSpec.norwegian4x4()
    private fun spec(steps: List<Step>) = base.copy(templateId = "custom:test", name = "test", hrBand = null, steps = steps)
    private fun work(sec: Int, rep: Int) = Step(StepKind.work, TargetKind.time, sec, RecoveryStyle.run, rep)
    private fun rec(sec: Int, rep: Int, style: RecoveryStyle = RecoveryStyle.jog) = Step(StepKind.recovery, TargetKind.time, sec, style, rep)

    private fun runTo(core: RecorderCore, from: Long, to: Long): List<Output> {
        val out = ArrayList<Output>()
        var t = from
        while (t <= to) {
            out.addAll(core.tick(t))
            t += 1000
        }
        return out
    }

    @Test
    fun `non-uniform time steps (pyramid) walk in order with exact boundaries and step status`() {
        val s = spec(listOf(work(60, 1), rec(60, 1, RecoveryStyle.walk), work(120, 2), rec(30, 2, RecoveryStyle.stand), work(60, 3)))
        val core = RecorderCore(RunMode.intervals, s)
        core.start(t0)
        assertNull(core.status(t0).stepIndex)
        core.startReps(t0 + 10_000)
        val st = core.status(t0 + 10_000)
        assertEquals(0, st.stepIndex)
        assertEquals(60_000L, st.stepRemainingMs)
        assertNull(st.stepRemainingM)
        val out = runTo(core, t0 + 10_000, t0 + 410_000)
        val autos: List<Long> = out.filterIsInstance<Output.Lap>().filter { it.source == LapSource.auto }.map { it.t - t0 - 10_000 }
        assertEquals(listOf(60_000L, 120_000L, 240_000L, 270_000L, 330_000L), autos)
        val phases: List<String> = out.filterIsInstance<Output.PhaseChanged>().map { "${it.phase}/${it.repIndex}/${it.phaseDurationMs}" }
        assertEquals(listOf("recovery/1/60000", "work/2/120000", "recovery/2/30000", "work/3/60000", "cooldown/3/null"), phases)
        assertNull(core.status(t0 + 410_000).stepIndex)
        assertNull(core.status(t0 + 410_000).stepRemainingMs)
    }

    @Test
    fun `a 0 s recovery goes straight into the next rep - no recovery phase, no lap`() {
        val s = spec(listOf(work(60, 1), rec(0, 1), work(60, 2)))
        val core = RecorderCore(RunMode.intervals, s)
        core.start(t0)
        core.startReps(t0)
        val out = runTo(core, t0, t0 + 130_000)
        val lapTimes: List<Long> = out.filterIsInstance<Output.Lap>().map { it.t - t0 }
        assertEquals(listOf(60_000L, 120_000L), lapTimes)
        val phases: List<String> = out.filterIsInstance<Output.PhaseChanged>().map { "${it.phase}/${it.repIndex}" }
        assertEquals(listOf("work/2", "cooldown/2"), phases)
        assertEquals(3, core.lapCount) // start LAP + 2 auto
    }

    @Test
    fun `restore rebuilds a non-uniform session from the journaled laps`() {
        val s = spec(listOf(work(60, 1), rec(90, 1), work(120, 2)))
        // start, LAP at 0, auto at 60 s (recovery), auto at 150 s (rep 2 work), last sample at 180 s.
        val lines = listOf(
            JournalLine.Header(0, 1_000, "r", "d", "a", "UTC", RunMode.intervals, s, Units.km),
            JournalLine.Lap(0, 1_000, LapSource.button),
            JournalLine.Lap(60_000, 61_000, LapSource.auto),
            JournalLine.Lap(150_000, 151_000, LapSource.auto),
            JournalLine.Sample(180_000, 181_000, null, null, null, null, null, null),
        )
        val replay = JournalReplay.read(lines.joinToString("") { JournalCodec.encode(it) + "\n" }.toByteArray())
        assertEquals(s, replay.header.session)
        val core = RecorderCore.restore(replay, nowT = 5_000_000)
        assertEquals(Phase.work, core.phase)
        assertEquals(2, core.repIndex)
        val st = core.status(5_000_000)
        assertEquals(2, st.stepIndex)
        assertEquals(90_000L, st.stepRemainingMs)
    }

    @Test
    fun `I1 rejects what it cannot run yet, and invalid specs`() {
        fun rejects(s: SessionSpec) = assertTrue(RecorderCore.unsupported(RunMode.intervals, s) != null, s.toString())
        rejects(spec(listOf(Step(StepKind.work, TargetKind.distance, 400, RecoveryStyle.run, 1))))
        rejects(spec(listOf(work(60, 1), Step(StepKind.recovery, TargetKind.equalToPreviousWork, 0, RecoveryStyle.jog, 1), work(60, 2))))
        rejects(spec(listOf(work(60, 1))).copy(warmupSeconds = 600))
        rejects(spec(listOf(work(60, 1))).copy(cooldownSeconds = 300))
        rejects(spec(listOf(work(60, 1))).copy(lapLockout = true))
        rejects(spec(listOf(work(30, 1))).copy(cueProfile = CueProfile.short))
        rejects(spec(listOf(work(10, 1)))) // invalid: under 15 s
        rejects(spec(emptyList()))
        assertNull(RecorderCore.unsupported(RunMode.intervals, base))
        val forty = ArrayList<Step>()
        for (r in 1..40) {
            forty.add(work(15, r))
            if (r < 40) forty.add(rec(0, r))
        }
        assertNull(RecorderCore.unsupported(RunMode.intervals, spec(forty)))
    }
}
