package app.runsolo.core.live

import app.runsolo.core.journal.JournalCodec
import app.runsolo.core.journal.JournalLine
import app.runsolo.core.journal.JournalReplay
import app.runsolo.core.journal.RunEvent
import app.runsolo.core.model.LiveBoard
import app.runsolo.core.model.LiveBoardKind
import app.runsolo.core.model.LiveContext
import app.runsolo.core.model.LiveEntry
import app.runsolo.core.model.LocationFix
import app.runsolo.core.model.RunMode
import app.runsolo.core.model.SessionSpec
import app.runsolo.core.model.Units
import app.runsolo.core.record.CueWords
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
        val said = ArrayList<Said>()
        var core = RecorderCore(mode, spec, config())
        var ticker = SampleTicker(wall = { 0L })
        var coach = LiveCoach(ctx, mode, spec)
        var prevT = 0L
        var prevD = 0.0
        var eastM = 0.0

        fun config(curve: List<Double>? = ctx?.cooperCurve) =
            RecorderCore.Config(volumeKeyLaps = false, cooperCurve = CooperCurve.fromFractions(curve) ?: CooperCurve.DEFAULT)

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
            coach.onTick(prevT, prevD, t, d) { core.status(it).activeMs }?.let { f -> speak(t, f.base, f) }
            prevT = t
            prevD = d
        }

        fun startReps(t: Long) = handle(core.startReps(t).second, t)

        private fun handle(out: List<RecorderCore.Output>, t: Long) {
            for (o in out) when (o) {
                is RecorderCore.Output.Lap -> lines.add(JournalLine.Lap(o.t, o.t, o.source))
                is RecorderCore.Output.Cue -> {
                    lines.add(JournalLine.Cue(o.t, o.t, o.kind))
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
            // As startResumed: the gap line first, so the restored clock excludes the dark span.
            lines.add(JournalLine.Gap(now, now, gapMs))
            val bytes = lines.joinToString("") { JournalCodec.encode(it) + "\n" }.toByteArray()
            val replay = JournalReplay.read(bytes)
            core = RecorderCore.restore(replay, now, config(replay.liveContext?.cooperCurve))
            ticker = SampleTicker(wall = { 0L })
            for (e in replay.events) if (e is RunEvent.Sample && e.hasFix) ticker.filter.offer(LocationFix(e.t, e.lat!!, e.lon!!, e.altM, e.accuracyM!!, e.speedMps))
            ticker.filter.reanchor() // the runner moved in the dark; the jump is not counted
            coach = LiveCoach(replay.liveContext, mode, spec, replay.cuesFired).also { it.resumeAt(core.distanceM) }
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
    fun `restore of a journal with no live context stays silent`() {
        val sh = freeRun(null, killAtS = 714)
        assertTrue(sh.said.isEmpty(), sh.said.toString())
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
}
