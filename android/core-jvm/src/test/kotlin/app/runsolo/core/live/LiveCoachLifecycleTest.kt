package app.runsolo.core.live

import app.runsolo.core.journal.JournalCodec
import app.runsolo.core.journal.JournalLine
import app.runsolo.core.journal.JournalReplay
import app.runsolo.core.journal.RunEvent
import app.runsolo.core.model.LapSource
import app.runsolo.core.model.LiveBoard
import app.runsolo.core.model.LiveBoardKind
import app.runsolo.core.model.LiveContext
import app.runsolo.core.model.LiveEntry
import app.runsolo.core.model.LocationFix
import app.runsolo.core.model.RunMode
import app.runsolo.core.model.SessionSpec
import app.runsolo.core.model.Units
import app.runsolo.core.record.CueWords
import app.runsolo.core.record.LapDispatch
import app.runsolo.core.record.RecorderCore
import app.runsolo.core.record.SampleTicker
import kotlin.math.cos
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNotEquals
import kotlin.test.assertTrue

/**
 * BLOCK-1 (Phase 4 §3.2 "Survives a kill"): a JVM shell that journals like RecordingSession
 * (header, `lctx`, samples, laps, cues, `cf`), is killed, and resumes from the journal the way
 * `startResumed` does (JournalReplay → RecorderCore.restore with the journaled curve → a
 * LiveCoach from the journaled context and fired cues, every passed point done).
 */
class LiveCoachLifecycleTest {
    private val lat0 = -33.8688
    private val lon0 = 151.2093
    private val mPerDegLon = 111_320.0 * cos(Math.toRadians(lat0))

    /** What the shell said, and when (device time). */
    data class Said(val t: Long, val text: String, val fire: LiveCoach.Fire?, val distanceM: Double)

    private inner class Shell(val mode: RunMode, val spec: SessionSpec?, val ctx: LiveContext?) {
        val lines = ArrayList<JournalLine>()

        /** Device time lost to kills so far (a hook-driven kill shifts every later second). */
        var offsetMs = 0L

        /** Cumulative (distance, active ms) at each lap, as the shell's lap summaries hold them. */
        val lapTotals = ArrayList<Pair<Double, Long>>()
        val said = ArrayList<Said>()
        var core = RecorderCore(mode, spec, config())
        var ticker = SampleTicker(wall = { 0L })
        var coach = LiveCoach(ctx, mode, spec)
        var goal = GoalCoach(spec, ctx)
        val goals = ArrayList<GoalCoach.Reached>()
        var prevT = 0L
        var prevD = 0.0
        var eastM = 0.0

        fun config(curve: List<Double>? = ctx?.cooperCurve) =
            RecorderCore.Config(volumeKeyLaps = true, cooperCurve = CooperCurve.fromFractions(curve) ?: CooperCurve.DEFAULT)

        fun start(t: Long) {
            lines.add(JournalLine.Header(t, t, "run", "d", "a", "UTC", mode, spec, Units.km))
            ctx?.let { lines.add(JournalLine.LiveContextLine(t, t, it)) }
            core.start(t)
            prevT = t
        }

        /** One second of running at [mps] (the fix delivered, then the tick, as the service). */
        fun second(t: Long, mps: Double) {
            eastM += mps
            ticker.onFix(LocationFix(t, lat0, lon0 + eastM / mPerDegLon, 10.0, 5.0, mps))
            for (s in ticker.tick(t)) lines.add(s)
            val d = ticker.distanceM
            val out = core.tick(t, d)
            handle(out, t)
            coach.onTick(prevT, prevD, t, d) { core.status(it).activeMs }?.let { k -> speak(t, k.base, k.fire) }
            prevT = t
            prevD = d
        }

        /** A LAP press between ticks, as the service's lap(): journaled with the core's outputs. */
        fun press(t: Long, source: LapSource) = handle(core.lap(source, t).second, t)

        fun startReps(t: Long) = handle(core.startReps(t).second, t)

        private fun handle(out: List<RecorderCore.Output>, t: Long) {
            // As RecordingSession: journaled in the core's order, sent with a step's end cue after its lap.
            for (o in out) when (o) {
                is RecorderCore.Output.Lap -> lines.add(JournalLine.Lap(o.t, o.t, o.source))
                is RecorderCore.Output.Cue -> lines.add(JournalLine.Cue(o.t, o.t, o.kind))
                else -> Unit
            }
            for (o in LapDispatch.ordered(out)) when (o) {
                is RecorderCore.Output.Lap -> {
                    // As LapDispatch: the distance interpolated at the lap's (back-dated) time.
                    val d = if (t <= prevT) ticker.distanceM else prevD + (ticker.distanceM - prevD) * (o.t - prevT).toDouble() / (t - prevT)
                    val a = core.status(o.t).activeMs
                    lapTotals.add(d to a)
                    coach.lapEnded(core.lapStep(o.index), d, a)
                }
                is RecorderCore.Output.Cue -> {
                    goal.atCue(o.kind, core.phase, core.finalStepEnd)?.let {
                        goals.add(it)
                        said.add(Said(t, it.text, null, ticker.distanceM))
                        coach.goalReachedAt(it.distanceM, if (it.distanceGoal && it.goalValue % 1_000 == 0) it.timeMs else null)
                    }
                    val base = CueWords.text(o.kind, o.value, spec, core.phase, core.repIndex, core.stepIndex, o.index)
                    val fire = coach.atCue(o.kind, o.index, o.value, core.phase, core.stepIndex, 0L, null)
                    if (base != null || fire != null) speak(t, base, fire)
                }
                else -> Unit
            }
        }

        private fun speak(t: Long, base: String?, fire: LiveCoach.Fire?) {
            val composed = CueComposer.compose(base, fire?.takeIf { it.speak }?.text)
            fire?.let { lines.add(JournalLine.CueFired(t, t, JournalLine.FiredKind.compare, it.key, it.index, core.status(t).elapsedMs)) }
            composed.text?.let { said.add(Said(t, it, fire, ticker.distanceM)) }
        }

        /** kill -9 at [t], dark for [gapMs], then resumeRecovered: everything rebuilt from the journal. */
        fun killAndResume(t: Long, gapMs: Long) {
            val now = t + gapMs
            offsetMs += gapMs
            // As startResumed: the gap line first, so the restored clock excludes the dark span.
            lines.add(JournalLine.Gap(now, now, gapMs))
            val bytes = lines.joinToString("") { JournalCodec.encode(it) + "\n" }.toByteArray()
            val replay = JournalReplay.read(bytes)
            core = RecorderCore.restore(replay, now, config(replay.liveContext?.cooperCurve))
            ticker = SampleTicker(wall = { 0L })
            for (e in replay.events) if (e is RunEvent.Sample && e.hasFix) ticker.filter.offer(LocationFix(e.t, e.lat!!, e.lon!!, e.altM, e.accuracyM!!, e.speedMps))
            ticker.filter.reanchor() // the runner moved in the dark; the jump is not counted
            coach = LiveCoach(replay.liveContext, mode, spec, replay.cuesFired).also {
                it.restoreReps(replay.events, core, lapTotals)
                it.resumeAt(core.distanceM)
            }
            goal = GoalCoach(spec, replay.liveContext).also { it.restored(reachedBeforeKill = core.finalStepEnd != null) }
            if (core.finalStepEnd != null) coach.goalReachedAt(core.distanceM, null)
            prevT = now
            prevD = ticker.distanceM
            eastM += 3.5 * gapMs / 1_000 // kept running in the dark
        }

        fun compares(): List<LiveCoach.Fire> = said.mapNotNull { it.fire }
    }

    private fun board(vararg km3Ms: Long) = LiveBoard(
        key = "be:5k", label = "5K", kind = LiveBoardKind.distance, targetM = 5_000.0,
        entries = km3Ms.mapIndexed { i, k3 -> LiveEntry("r$i", 0, fromStartSplitsMs = List(5) { k -> k3 * (k + 1) / 3 }, finalMetric = k3 * 5 / 3.0) },
    )

    private val ctx5k = LiveContext(boards = listOf(board(800_000, 900_000, 1_000_000)), builtAtMs = 0, engineVersion = 1)

    private fun freeRun(ctx: LiveContext?, killAtS: Int?, seconds: Int = 1_300): Shell {
        val sh = Shell(RunMode.free, null, ctx)
        sh.start(0)
        var s = 1
        while (s <= seconds) {
            sh.second(s * 1_000L, 3.5)
            if (s == killAtS) {
                sh.killAndResume(s * 1_000L, 20_000)
                s += 20
            }
            s++
        }
        return sh
    }

    @Test
    fun `kill at km 2 5 - after the restore the km 3 compare fires once with the right rank`() {
        val sh = freeRun(ctx5k, killAtS = 714) // 714 s × 3.5 m/s ≈ 2.5 km
        val km3 = sh.compares().filter { it.index == 3 }
        assertEquals(1, km3.size, sh.said.toString())
        // Active time excludes the dark 20 s: about 858 s at km 3, behind 800, ahead of 900.
        assertEquals(2, km3.single().result.rank)
        assertEquals(4, km3.single().result.of)
        assertTrue(km3.single().result.deltaMs!! in 50_000L..70_000L, "${km3.single().result.deltaMs}")
        assertEquals(listOf(1, 2, 3, 4), sh.compares().map { it.index }, "km 1-2 before the kill, 3-4 after, each once")
        for (km in 1..4) assertEquals(1, sh.said.count { it.text.startsWith("$km k,") }, "km $km split said once: ${sh.said}")
    }

    @Test
    fun `kill 1 s after the km 3 compare - it is never said again`() {
        val probe = freeRun(ctx5k, killAtS = null)
        val at = probe.said.first { it.fire?.index == 3 }.t
        val sh = freeRun(ctx5k, killAtS = (at / 1_000 + 1).toInt())
        assertEquals(1, sh.compares().count { it.index == 3 }, sh.said.toString())
        assertEquals(1, sh.compares().count { it.index == 4 })
    }

    @Test
    fun `restore of a journal with no live context compares nothing, the splits go on`() {
        val sh = freeRun(null, killAtS = 714)
        assertTrue(sh.compares().isEmpty(), sh.said.toString())
        assertEquals(listOf("1 k,", "2 k,", "3 k,", "4 k,"), sh.said.map { it.text.substringBefore(" ") + " k," })
        val bytes = sh.lines.joinToString("") { JournalCodec.encode(it) + "\n" }.toByteArray()
        assertEquals(null, JournalReplay.read(bytes).liveContext)
    }

    @Test
    fun `Cooper kill at 5 30 - the 6 00 projection uses the journaled curve and ranks once`() {
        // A fast-start personal curve, far from the default at 6:00, and three past tests.
        val personal = CooperCurve.fromMinuteSpeeds(listOf(1.3, 1.2, 1.1, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 0.9, 0.9, 1.0)).fractions
        val ctx = LiveContext(boards = emptyList(), cooperCurve = personal, cooperHistory = listOf(45.0, 49.0, 60.0), builtAtMs = 0, engineVersion = 1)
        val sh = Shell(RunMode.cooper, SessionSpec.COOPER, ctx)
        sh.start(0)
        for (s in 1..60) sh.second(s * 1_000L, 2.5)
        val workStartD = sh.ticker.distanceM
        sh.startReps(60_000)
        var s = 61
        while (s <= 60 + 720 + 30) {
            sh.second(s * 1_000L, 3.5)
            if (s == 60 + 330) {
                sh.killAndResume(s * 1_000L, 10_000)
                s += 10
            }
            s++
        }
        val six = sh.said.filter { it.text.startsWith("6 minutes.") }
        assertEquals(1, six.size, sh.said.toString())
        val covered = six.single().distanceM - workStartD
        val withPersonal = CooperProjection.cue(6, CooperProjection.project(CooperCurve.fromFractions(personal)!!, 360.0, covered)!!)
        val withDefault = CooperProjection.cue(6, CooperProjection.project(CooperCurve.DEFAULT, 360.0, covered)!!)
        assertNotEquals(withDefault, withPersonal, "the curves must differ at 6:00 for this check to mean anything")
        assertTrue(six.single().text.startsWith(withPersonal), "${six.single().text} vs $withPersonal")
        assertEquals(6, six.single().fire!!.index)
        assertEquals(listOf(3, 6, 9), sh.compares().map { it.index }, "rank at 3, 6 and 9 only, once each")
        assertEquals(1, sh.said.count { it.text.startsWith("5 minutes.") }, "no minute is said again (or late) after the restore")
    }

    // ---- live rep paces by step (#48 review P1, P2), through the real core and a restore ----

    private fun intervals(recoveryS: Int) = SessionSpec(
        templateId = "custom:t", templateVersion = 1, name = "3 × 400 m", warmupSeconds = null, cooldownSeconds = null,
        lapLockout = false, cueProfile = app.runsolo.core.model.CueProfile.standard, hrBand = null,
        steps = (1..3).flatMap { r ->
            listOfNotNull(
                app.runsolo.core.model.Step(app.runsolo.core.model.StepKind.work, app.runsolo.core.model.TargetKind.distance, 400, app.runsolo.core.model.RecoveryStyle.run, r),
                if (r < 3) app.runsolo.core.model.Step(app.runsolo.core.model.StepKind.recovery, app.runsolo.core.model.TargetKind.time, recoveryS, app.runsolo.core.model.RecoveryStyle.jog, r) else null,
            )
        },
    )

    /** 60 s warm-up, LAP, then 4 m/s in work and 2 m/s otherwise until [seconds]; hooks per second. */
    private fun intervalRun(spec: SessionSpec, seconds: Int, ctx: LiveContext? = null, each: (Shell, Int) -> Unit = { _, _ -> }): Shell {
        val sh = Shell(RunMode.intervals, spec, ctx)
        sh.start(0)
        var s = 1
        while (s <= seconds) {
            val mps = if (sh.core.phase == app.runsolo.core.model.Phase.work) 4.0 else 2.0
            sh.second(s * 1_000L + sh.offsetMs, mps)
            if (s == 60) sh.press(60_000, LapSource.button)
            each(sh, s)
            s++
        }
        return sh
    }

    @Test
    fun `0 s recoveries - three reps back to back, each its own 400 m at work pace`() {
        val sh = intervalRun(intervals(0), 60 + 3 * 105)
        val paces = sh.coach.repPaces
        assertEquals(3, paces.size, paces.toString())
        assertTrue(paces.all { it != null && it in 245.0..256.0 }, "4 m/s is 250 s/km: $paces")
    }

    @Test
    fun `a volume-key lap mid-rep splits the lap, not the rep`() {
        val sh = intervalRun(intervals(60), 60 + 3 * 105 + 2 * 60 + 10) { shell, s -> if (s == 110) shell.press(110_500, LapSource.volumeKey) }
        val paces = sh.coach.repPaces
        assertEquals(3, paces.size, paces.toString())
        assertTrue(paces.all { it != null && it in 245.0..256.0 }, "no half rep, no shift: $paces")
    }

    @Test
    fun `restore - the reps before the kill come back by step, the rep the kill cut is unclean`() {
        var killed = false
        val sh = intervalRun(intervals(0), 60 + 3 * 105 + 40) { shell, s ->
            if (!killed && s == 60 + 150) { // mid rep 2
                killed = true
                shell.killAndResume(s * 1_000L + shell.offsetMs, 10_000)
            }
        }
        val paces = sh.coach.repPaces
        assertEquals(3, paces.size, paces.toString())
        assertTrue(paces[0] != null && paces[0]!! in 245.0..256.0, "rep 1 rebuilt from the journal: $paces")
        assertEquals(null, paces[1], "rep 2 spanned the kill")
        assertTrue(paces[2] != null && paces[2]!! in 245.0..256.0, "rep 3 is clean: $paces")
    }

    @Test
    fun `the last rep's compare rides the cool-down cue and counts every rep`() {
        val board = LiveBoard(
            key = "d400x3", label = "3 × 400 m", kind = LiveBoardKind.intervals,
            entries = listOf(240.0, 260.0).mapIndexed { i, p -> LiveEntry("r$i", 0, liveRepPacesSecPerKm = List(3) { p }, finalMetric = p) },
        )
        val ctx = LiveContext(boards = listOf(board), builtAtMs = 0, engineVersion = 1)
        val sh = intervalRun(intervals(60), 60 + 3 * 105 + 2 * 60 + 30, ctx)
        assertEquals(listOf(1, 2, 3), sh.compares().map { it.index }, sh.said.toString())
        val last = sh.said.single { it.fire?.index == 3 }
        assertTrue(last.text.startsWith("Done. Cool down."), last.text)
        assertEquals(2, last.fire!!.result.rank, "250 s/km over all 3 reps: behind 240, ahead of 260")
    }

    // ---- GOAL runs (§G, G2) ----

    private fun goalRun(spec: SessionSpec, seconds: Int, ctx: LiveContext? = null, killAtS: Int? = null): Shell {
        val sh = Shell(RunMode.intervals, spec, ctx)
        sh.start(0)
        var s = 1
        while (s <= seconds) {
            sh.second(s * 1_000L + sh.offsetMs, if (sh.core.phase == app.runsolo.core.model.Phase.work) 4.0 else 2.0)
            if (s == killAtS) sh.killAndResume(s * 1_000L + sh.offsetMs, 10_000)
            s++
        }
        return sh
    }

    @Test
    fun `a 5K goal - said once at 5 km with the time, then km splits only in the open cool-down`() {
        val sh = goalRun(SessionSpec.goalDistance(5_000, "5K"), 1_252 + 600)
        val g = sh.goals.single()
        assertTrue(g.distanceGoal)
        assertEquals(5_000.0, g.distanceM, 0.01)
        assertTrue(g.timeMs in 1_250_000L..1_253_000L, "about 1250 s at 4 m/s (filter): ${g.timeMs}")
        assertEquals("5K done, ${CueWords.clock(g.timeMs.toDouble())}.", g.text)
        assertEquals(1, sh.said.count { it.text.startsWith("5K done") })
        // The cool-down runs at 2 m/s: 6 k comes 500 s after the goal; no "5 k" split after "5K done".
        assertEquals(listOf("6 k,"), sh.said.filter { Regex("^\\d+ k,").containsMatchIn(it.text) }.map { it.text.substringBefore(" k,") + " k," })
    }

    @Test
    fun `new best only against the goal's own board, and never when a kill fell before the goal`() {
        val board = LiveBoard(
            key = "be:5000", label = "5K", kind = LiveBoardKind.distance, targetM = 5_000.0,
            entries = listOf(1_300_000L, 1_400_000L).mapIndexed { i, ms -> LiveEntry("r$i", 0, fromStartSplitsMs = List(5) { k -> ms * (k + 1) / 5 }, finalMetric = ms.toDouble()) },
        )
        val ctx = LiveContext(boards = listOf(board), builtAtMs = 0, engineVersion = 1)
        val best = goalRun(SessionSpec.goalDistance(5_000, "5K"), 1_300, ctx).goals.single()
        assertTrue(best.newBest)
        assertTrue(best.text.endsWith(", new best."), best.text)
        val interrupted = goalRun(SessionSpec.goalDistance(5_000, "5K"), 1_320, ctx, killAtS = 600).goals.single()
        assertTrue(interrupted.interrupted)
        assertTrue(!interrupted.newBest, "a kill before the goal: goal time with no distance behind it")
    }

    @Test
    fun `restore after the goal - never said again, the cool-down goes on`() {
        val sh = goalRun(SessionSpec.goalDistance(5_000, "5K"), 1_252 + 600, killAtS = 1_300)
        assertEquals(1, sh.goals.size, sh.said.toString())
        assertEquals(1, sh.said.count { it.text.startsWith("5K done") })
    }

    @Test
    fun `a 30-minute goal - the distance at 30 minutes, said once`() {
        val sh = goalRun(SessionSpec.goalTime(1_800, "30 min"), 1_800 + 120)
        val g = sh.goals.single()
        assertTrue(!g.distanceGoal)
        assertEquals(1_800_000L, g.timeMs)
        assertEquals("30 min done, ${String.format(java.util.Locale.US, "%.2f", g.distanceM / 1_000)} km.", g.text)
        assertTrue(g.distanceM in 7_150.0..7_210.0, "about 30 min at 4 m/s: ${g.distanceM}")
    }

    @Test
    fun `a 30-minute goal - new best only against its distance-in-time board`() {
        fun board(key: String, kind: LiveBoardKind) = LiveBoard(
            key = key, label = "30 min", kind = kind,
            entries = listOf(6_900.0, 7_000.0).mapIndexed { i, m -> LiveEntry("r$i", 0, cooperMinuteM = List(30) { k -> m * (k + 1) / 30 }, finalMetric = m) },
        )
        val onBoard = LiveContext(boards = listOf(board("be:t1800", LiveBoardKind.distanceInTime)), builtAtMs = 0, engineVersion = 1)
        val best = goalRun(SessionSpec.goalTime(1_800, "30 min"), 1_800 + 60, onBoard).goals.single()
        assertTrue(best.newBest)
        assertTrue(best.text.endsWith(", new best."), best.text)
        val otherKind = LiveContext(boards = listOf(board("be:t1800", LiveBoardKind.cooper)), builtAtMs = 0, engineVersion = 1)
        assertTrue(!goalRun(SessionSpec.goalTime(1_800, "30 min"), 1_800 + 60, otherKind).goals.single().newBest)
    }

    @Test
    fun `a LAP in a goal marks a lap and never ends the goal early`() {
        val sh = Shell(RunMode.intervals, SessionSpec.goalDistance(3_000, "3K"), null)
        sh.start(0)
        for (s in 1..900) {
            sh.second(s * 1_000L, 4.0)
            if (s == 300) sh.press(300_500, LapSource.button)
        }
        val g = sh.goals.single()
        assertEquals(3_000.0, g.distanceM, 0.01)
        assertTrue(g.timeMs > 700_000, "the goal ended at 3 km, not at the LAP: ${g.timeMs}")
    }
}
