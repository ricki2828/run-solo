package app.runsolo.core.record

import app.runsolo.core.gps.PointFilter
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
import app.runsolo.core.replay.TraceFixture
import kotlin.math.abs
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull
import kotlin.test.assertTrue

/** Phase 3 I2 (§3.6): distance steps, equal-time recoveries, fixed warm-up/cool-down, lockout, cue profiles, auto-stop, restore. */
class RecorderCoreI2Test {
    private val t0 = 1_000_000L
    private val base = SessionSpec.norwegian4x4().copy(templateId = "custom:t", name = "t", hrBand = null)
    private fun spec(vararg steps: Step) = base.copy(steps = steps.toList())
    private fun work(sec: Int, rep: Int) = Step(StepKind.work, TargetKind.time, sec, RecoveryStyle.run, rep)
    private fun workM(m: Int, rep: Int) = Step(StepKind.work, TargetKind.distance, m, RecoveryStyle.run, rep)
    private fun rec(sec: Int, rep: Int, style: RecoveryStyle = RecoveryStyle.jog) = Step(StepKind.recovery, TargetKind.time, sec, style, rep)
    private fun recM(m: Int, rep: Int) = Step(StepKind.recovery, TargetKind.distance, m, RecoveryStyle.jog, rep)
    private fun recEq(rep: Int) = Step(StepKind.recovery, TargetKind.equalToPreviousWork, 0, RecoveryStyle.walk, rep)

    /** Ticks at 1 Hz from [from] for [seconds], distance growing at [mps] from [d0]; returns outputs and the final distance. */
    private fun drive(core: RecorderCore, from: Long, seconds: Int, mps: Double, d0: Double, gpsOk: Boolean = true): Pair<List<Output>, Double> {
        val out = ArrayList<Output>()
        var d = d0
        for (i in 1..seconds) {
            d += mps
            out.addAll(core.tick(from + i * 1000L, d, gpsOk))
        }
        return out to d
    }

    private fun laps(out: List<Output>) = out.filterIsInstance<Output.Lap>()
    private fun cues(out: List<Output>) = out.filterIsInstance<Output.Cue>()

    @Test
    fun `distance step - boundary interpolated between ticks, next step starts at the exact target`() {
        val s = spec(workM(400, 1), rec(60, 1), workM(400, 2))
        val core = RecorderCore(RunMode.intervals, s)
        core.start(t0)
        core.tick(t0, 10.0) // 10 m of warm-up
        core.startReps(t0)
        val st = core.status(t0)
        assertEquals(0, st.stepIndex)
        assertEquals(400.0, st.stepRemainingM)
        assertNull(st.stepRemainingMs)
        // 3 m/s: 400 m is covered at 133.33 s (tick 134 sits at 402 m).
        val (out, _) = drive(core, t0, 140, 3.0, 10.0)
        val l = laps(out)
        assertEquals(1, l.size)
        assertEquals(t0 + 133_333, l[0].t, "interpolated to the ms")
        assertEquals(LapSource.auto, l[0].source)
        assertEquals(Phase.recovery, core.phase)
        // The recovery started at the boundary, so at t0+140 s it has run 6.67 s.
        assertEquals(60_000L - 6_667, core.status(t0 + 140_000).stepRemainingMs)
        // Rep 2 starts at the target (410 m total), not at the tick's 412 m.
        val (out2, _) = drive(core, t0 + 140_000, 70, 3.0, 430.0)
        assertEquals(Phase.work, core.phase)
        val rep2Start = laps(out2).single().t
        assertEquals(t0 + 193_333, rep2Start)
        // The recovery ended at 193.33 s, 590 m by interpolation; at 210 s the total is 640 m.
        assertEquals(350.0, core.status(t0 + 210_000).stepRemainingM!!, 0.01)
    }

    @Test
    fun `distance step - no GPS, no end on its own and no extrapolation, resumes when distance moves`() {
        val core = RecorderCore(RunMode.intervals, spec(workM(400, 1)))
        core.start(t0)
        core.startReps(t0)
        val (a, d) = drive(core, t0, 100, 3.0, 0.0) // 300 m
        assertTrue(laps(a).isEmpty())
        val (b, d2) = drive(core, t0 + 100_000, 120, 0.0, d, gpsOk = false) // tunnel: no distance for 2 min
        assertTrue(b.none { it is Output.Lap || it is Output.PhaseChanged })
        assertEquals(100.0, core.status(t0 + 220_000).stepRemainingM)
        val (c, _) = drive(core, t0 + 220_000, 40, 3.0, d2)
        assertEquals(1, c.filterIsInstance<Output.PhaseChanged>().count { it.phase == Phase.cooldown })
    }

    @Test
    fun `equal-time recovery lasts as long as the work step took, manual LAP included`() {
        val s = spec(workM(400, 1), recEq(1), workM(400, 2), recEq(2), workM(400, 3))
        val core = RecorderCore(RunMode.intervals, s)
        core.start(t0)
        core.startReps(t0)
        drive(core, t0, 101, 4.0, 0.0) // 400 m at exactly 100 s
        assertEquals(Phase.recovery, core.phase)
        assertEquals(100_000L - 1_000, core.status(t0 + 101_000).stepRemainingMs)
        drive(core, t0 + 101_000, 100, 0.0, 404.0)
        assertEquals(Phase.work, core.phase)
        assertEquals(2, core.repIndex)
        // Rep 2 ended early by a manual LAP after 80 s: its recovery is 80 s.
        val (d, out) = core.lap(LapSource.button, t0 + 200_000 + 80_000)
        assertEquals(LapDecision.accepted, d)
        assertEquals(Phase.recovery, core.phase)
        assertEquals(80_000L, out.filterIsInstance<Output.PhaseChanged>().single().phaseDurationMs)
    }

    @Test
    fun `fixed warm-up ends by itself, fixed cool-down ends with an auto lap and stays open`() {
        val s = spec(work(60, 1)).copy(warmupSeconds = 300, cooldownSeconds = 300)
        val core = RecorderCore(RunMode.intervals, s)
        val start = core.start(t0)
        assertEquals(300_000L, start.filterIsInstance<Output.PhaseChanged>().single().phaseDurationMs)
        assertEquals(300_000L, core.status(t0).phaseRemainingMs)
        assertNull(core.status(t0).stepIndex)
        val (out, _) = drive(core, t0, 700, 3.0, 0.0)
        assertEquals(listOf(300_000L, 360_000L, 660_000L), laps(out).map { it.t - t0 })
        assertEquals(listOf(Phase.work, Phase.cooldown), out.filterIsInstance<Output.PhaseChanged>().map { it.phase })
        assertEquals(listOf(CueKind.thirtySeconds, CueKind.phaseEnd), cues(out).take(2).map { it.kind })
        assertEquals(Phase.cooldown, core.phase)
        assertEquals(0L, core.status(t0 + 700_000).phaseRemainingMs, "untimed after the fixed cool-down")
        assertTrue(out.none { it is Output.AutoStop })
        // startReps during a fixed warm-up still starts rep 1 early.
        val early = RecorderCore(RunMode.intervals, s)
        early.start(t0)
        assertEquals(LapDecision.accepted, early.startReps(t0 + 30_000).first)
        assertEquals(Phase.work, early.phase)
    }

    @Test
    fun `parkrun - one 5000 m step with auto-stop - projections each km, stops at 5 00 km, no lap on the finish`() {
        val parkrun = SessionSpec(
            templateId = "parkrun", templateVersion = 1, name = "parkrun", warmupSeconds = null, cooldownSeconds = null,
            lapLockout = false, autoStop = true, cueProfile = CueProfile.standard, hrBand = null, steps = listOf(workM(5000, 1)),
        )
        val core = RecorderCore(RunMode.intervals, parkrun)
        core.start(t0)
        drive(core, t0, 120, 1.5, 0.0) // warm-up jog, 180 m
        core.startReps(t0 + 120_000)
        val (out, _) = drive(core, t0 + 120_000, 1300, 4.0, 180.0)
        val stop = out.filterIsInstance<Output.AutoStop>().single()
        assertEquals(t0 + 120_000 + 1_250_000, stop.t, "5000 m at 4 m/s")
        assertTrue(core.autoStopped)
        assertTrue(laps(out).isEmpty(), "the stop ends the 5 km lap; no marker on the finish line")
        val proj = cues(out).filter { it.kind == CueKind.projection }
        assertEquals(4, proj.size)
        assertTrue(proj.all { abs(it.value!! - 1_250_000) < 1_500 }, "projected finish ~20:50: ${proj.map { it.value }}")
        assertEquals(listOf(CueKind.halfway, CueKind.distanceToGo), cues(out).map { it.kind }.filter { it == CueKind.halfway || it == CueKind.distanceToGo })
        // Nothing after the stop request (the shell stops the recording).
        assertEquals(stop, out.last())
        assertEquals(Phase.cooldown, core.phase)
    }

    @Test
    fun `auto-stop after a fixed cool-down`() {
        val s = spec(work(60, 1)).copy(cooldownSeconds = 300, autoStop = true)
        val core = RecorderCore(RunMode.intervals, s)
        core.start(t0)
        core.startReps(t0)
        val (out, _) = drive(core, t0, 400, 3.0, 0.0)
        assertEquals(listOf(60_000L), laps(out).map { it.t - t0 }, "an auto lap at the rep end, none at the cool-down end")
        assertEquals(t0 + 360_000, out.filterIsInstance<Output.AutoStop>().single().t)
    }

    @Test
    fun `lap lockout ignores manual laps during work, not in recovery`() {
        val s = spec(work(120, 1), rec(60, 1), work(120, 2)).copy(lapLockout = true)
        val core = RecorderCore(RunMode.intervals, s)
        core.start(t0)
        core.startReps(t0)
        assertEquals(LapDecision.ignoredLockout, core.lap(LapSource.notification, t0 + 30_000).first)
        assertEquals(LapDecision.ignoredLockout, core.lap(LapSource.button, t0 + 40_000).first)
        drive(core, t0, 130, 3.0, 0.0)
        assertEquals(Phase.recovery, core.phase)
        assertEquals(LapDecision.accepted, core.lap(LapSource.button, t0 + 140_000).first)
        assertEquals(Phase.work, core.phase)
    }

    @Test
    fun `short cue profile - start, 3-2-1 countdown, end, last rep called`() {
        val s = spec(work(30, 1), rec(30, 1), work(30, 2)).copy(cueProfile = CueProfile.short)
        val core = RecorderCore(RunMode.intervals, s)
        core.start(t0)
        val (_, first) = core.startReps(t0)
        assertEquals(listOf(CueKind.start), cues(first).map { it.kind })
        val (out, _) = drive(core, t0, 95, 3.0, 0.0)
        assertEquals(
            listOf(
                CueKind.countdown to 27_000L, CueKind.phaseEnd to 30_000L, CueKind.start to 30_000L,
                CueKind.countdown to 57_000L, CueKind.phaseEnd to 60_000L, CueKind.start to 60_000L, CueKind.lastRep to 60_000L,
                CueKind.countdown to 87_000L, CueKind.phaseEnd to 90_000L,
            ),
            cues(out).map { it.kind to it.t - t0 },
        )
    }

    @Test
    fun `Cooper - LAP ignored, startReps starts 12 00, minute marks, projections from 3 00, suppressed on weak GPS`() {
        val core = RecorderCore(RunMode.cooper, SessionSpec.COOPER)
        core.start(t0)
        assertEquals(Phase.warmup, core.phase)
        assertEquals(LapDecision.ignoredModeNoLaps, core.lap(LapSource.button, t0 + 1_000).first)
        core.tick(t0 + 60_000, 0.0) // the warm-up ticks (distance counted from here)
        assertEquals(LapDecision.accepted, core.startReps(t0 + 60_000).first)
        assertEquals(Phase.work, core.phase)
        val w = t0 + 60_000
        // 3.5 m/s; GPS weak around the 6:00 projection.
        val (a, d) = drive(core, w, 350, 3.5, 0.0)
        val (b, d2) = drive(core, w + 350_000, 20, 3.5, d, gpsOk = false)
        val (c, _) = drive(core, w + 370_000, 360, 3.5, d2)
        val all = a + b + c
        val kinds = cues(all).map { it.kind to (it.t - w) / 1000 }
        assertEquals(listOf(60L, 120L, 240L, 300L, 420L, 480L, 600L), kinds.filter { it.first == CueKind.minuteMark }.map { it.second })
        val proj = cues(all).filter { it.kind == CueKind.projection }
        assertEquals(listOf(180L, 540L, 660L), proj.map { (it.t - w) / 1000 }, "6:00 suppressed on weak GPS")
        assertTrue(proj.all { abs(it.value!! - 3.5 * 720) < 1.0 }, proj.map { it.value }.toString())
        assertEquals(1, cues(all).count { it.kind == CueKind.countdown })
        assertEquals(w + 720_000, laps(all).single().t, "the 12:00 auto lap")
        assertEquals(Phase.cooldown, core.phase)
        assertTrue(all.none { it is Output.AutoStop })
    }

    // ---- restore (W2) ----

    /** A live run mirrored into a journal: the shell's order (sample, then core.tick with the filter's distance). */
    private class Live(val spec: SessionSpec, segments: List<Pair<Int, Double>>) {
        val fixes = TraceFixture.straightLine(segments, accuracyM = 5.0, startT = 0)
        val core = RecorderCore(RunMode.intervals, spec)
        val filter = PointFilter()
        val lines = ArrayList<JournalLine>()

        init {
            lines.add(JournalLine.Header(0, 1_000, "r", "d", "a", "UTC", RunMode.intervals, spec, Units.km))
            core.start(0)
        }

        fun emit(out: List<Output>) {
            for (o in out) if (o is Output.Lap) lines.add(JournalLine.Lap(o.t, 1_000 + o.t, o.source))
        }

        /** Runs seconds 1..[untilS]; [at] fires before the tick of that second. */
        fun run(untilS: Int, at: (Int) -> Unit = {}) {
            for (i in 1..untilS) {
                val f = fixes[i]
                at(i)
                filter.offer(f)
                lines.add(JournalLine.Sample(f.t, 1_000 + f.t, f.lat, f.lon, f.altM, f.accuracyM, f.speedMps, null))
                emit(core.tick(f.t, filter.totalM))
            }
        }

        fun restored(): RecorderCore = RecorderCore.restore(JournalReplay.read(lines.joinToString("") { JournalCodec.encode(it) + "\n" }.toByteArray()), nowT = 9_000_000)
    }

    private val eight400 = spec(*(1..3).flatMap { r -> if (r < 3) listOf(workM(400, r), recM(200, r)) else listOf(workM(400, r)) }.toTypedArray())

    @Test
    fun `restore mid 400 m - right rep, right metres left`() {
        val live = Live(eight400, listOf(30 to 2.0, 1000 to 4.0))
        live.run(250) { if (it == 30) live.emit(live.core.startReps(30_000).second) }
        val want = live.core.status(250_000)
        val core = live.restored()
        val got = core.status(9_000_000)
        assertEquals(want.phase, got.phase)
        assertEquals(want.repIndex, got.repIndex)
        assertEquals(want.stepIndex, got.stepIndex)
        assertEquals(want.stepRemainingM!!, got.stepRemainingM!!, 1.0)
    }

    @Test
    fun `restore 2 s after a 400 m auto lap - no duplicate lap, right metres into the recovery`() {
        val live = Live(eight400, listOf(30 to 2.0, 1000 to 4.0))
        live.run(132) { if (it == 30) live.emit(live.core.startReps(30_000).second) } // 400 m at ~130 s
        val autoLaps = live.lines.filterIsInstance<JournalLine.Lap>().filter { it.source == LapSource.auto }
        assertEquals(1, autoLaps.size)
        val want = live.core.status(132_000)
        val core = live.restored()
        assertEquals(Phase.recovery, core.phase)
        assertEquals(want.stepRemainingM!!, core.status(9_000_000).stepRemainingM!!, 1.0)
        // The next live tick with a little more distance must not lap again.
        val next = core.tick(9_001_000, live.filter.totalM + 4.0)
        assertTrue(next.none { it is Output.Lap }, next.toString())
        assertEquals(2, core.lapCount)
    }

    @Test
    fun `restore killed exactly on a distance boundary - lap journaled, next step started`() {
        val live = Live(eight400, listOf(30 to 2.0, 1000 to 4.0))
        var boundaryS = -1
        live.run(200) {
            if (it == 30) live.emit(live.core.startReps(30_000).second)
            if (boundaryS < 0 && live.lines.count { l -> l is JournalLine.Lap && l.source == LapSource.auto } == 1) boundaryS = it
        }
        // Cut the journal right after the first auto lap line.
        val cut = live.lines.indexOfFirst { it is JournalLine.Lap && it.source == LapSource.auto }
        val lines = live.lines.subList(0, cut + 1)
        val core = RecorderCore.restore(JournalReplay.read(lines.joinToString("") { JournalCodec.encode(it) + "\n" }.toByteArray()), nowT = 9_000_000)
        assertEquals(Phase.recovery, core.phase)
        assertEquals(1, core.stepIndex)
        assertEquals(1, core.repIndex)
        assertTrue(core.status(9_000_000).stepRemainingM!! in 195.0..200.0)
    }

    @Test
    fun `restore - Yasso equal time after a rep ended by manual LAP uses the measured time`() {
        val s = spec(workM(800, 1), recEq(1), workM(800, 2))
        val live = Live(s, listOf(30 to 2.0, 1000 to 4.0))
        live.run(150) {
            if (it == 30) live.emit(live.core.startReps(30_000).second)
            if (it == 130) live.emit(live.core.lap(LapSource.button, 130_000).second) // rep 1 cut at 100 s (400 m)
        }
        assertEquals(Phase.recovery, live.core.phase)
        val core = live.restored()
        assertEquals(Phase.recovery, core.phase)
        assertEquals(live.core.status(150_000).stepRemainingMs, core.status(9_000_000).stepRemainingMs)
        assertEquals(80_000L, core.status(9_000_000).stepRemainingMs) // 100 s recovery, 20 s in
    }

    @Test
    fun `restore after an auto-stop - stopped state carried`() {
        val s = spec(workM(400, 1)).copy(autoStop = true)
        val live = Live(s, listOf(30 to 2.0, 200 to 4.0))
        live.run(140) { if (it == 30) live.emit(live.core.startReps(30_000).second) }
        assertTrue(live.core.autoStopped)
        // No marker was journaled for the finish: the restored core is still in the step, past its target, and stops on the next tick.
        val core = live.restored()
        assertEquals(RecorderState.recording, core.state)
        val out = core.tick(9_001_000, live.filter.totalM)
        assertTrue(out.any { it is Output.AutoStop }, out.toString())
    }

    @Test
    fun `a distance step started by a press between ticks counts from the interpolated press point`() {
        val core = RecorderCore(RunMode.intervals, spec(workM(400, 1)))
        core.start(t0)
        core.tick(t0 + 1_000, 3.0)
        core.tick(t0 + 2_000, 6.0)
        core.startReps(t0 + 2_500) // halfway between ticks: 7.5 m, not the last tick's 6 m
        core.tick(t0 + 3_000, 9.0)
        assertEquals(400.0 - 1.5, core.status(t0 + 3_000).stepRemainingM!!, 1e-9)
        // The boundary follows: 400 m from 7.5 m is reached at 407.5 m.
        val (out, _) = drive(core, t0 + 3_000, 140, 3.0, 9.0)
        assertEquals(t0 + 3_000 + 132_833, laps(out).single().t)
    }
}
