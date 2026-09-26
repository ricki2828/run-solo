package app.runsolo.core.contract

import app.runsolo.core.journal.JournalCodec
import app.runsolo.core.journal.JournalLine
import app.runsolo.core.journal.JournalReplay
import app.runsolo.core.journal.RunEvent
import app.runsolo.core.json.Json
import app.runsolo.core.live.CooperCurve
import app.runsolo.core.live.CueComposer
import app.runsolo.core.live.GoalCoach
import app.runsolo.core.live.LiveCoach
import app.runsolo.core.live.NudgeFollowUp
import app.runsolo.core.live.SpeechClock
import app.runsolo.core.model.CueKind
import app.runsolo.core.model.LapSource
import app.runsolo.core.model.LocationFix
import app.runsolo.core.model.Units
import app.runsolo.core.record.CueWords
import app.runsolo.core.record.LapDispatch
import app.runsolo.core.record.RecorderCore
import app.runsolo.core.record.SampleTicker
import app.runsolo.core.replay.ReplayScenarios
import java.io.File

/**
 * Phase 4 T4: what each `t4-*` replay says and when (trace ms), from a JVM shell that mirrors
 * `RecordingSession`'s cue path call for call: the same tick order (press, sample, lap flush,
 * core tick, km compare), [LapDispatch] holding a rep-end cue behind a manual lap, the compare
 * and nudge from [LiveCoach], the goal line from [GoalCoach], and `CuePlayer`'s composition
 * ([CueComposer], 16 words) with the 3 s stale rule on the replay clock ([SpeechClock]). The
 * emulator job replays the same kind through the real service and checks its `said` log lines
 * against this file (tools/check_replay_transcript.py). The stop cue ("Run saved") is left out on
 * both sides: an auto-stop lands a moment later on the device.
 */
object TranscriptFixture {
    const val DIR = "src/test/fixtures/transcripts"

    data class Said(val t: Long, val text: String)

    /** A compare or nudge that was spoken, keyed as its `cf` line (`compare:key#i`, `nudge:rule#i`). */
    data class Extra(val t: Long, val key: String)

    /** A kill -9 at trace [atMs], dark for [gapMs] (those fixes never arrive), then resumeRecovered. */
    data class Kill(val atMs: Long, val gapMs: Long)

    fun all(): Map<String, String> = ReplayScenarios.T4_KINDS.associateWith { kind ->
        val shell = Shell(ReplayScenarios.create(kind)!!).also { it.run() }
        encode(kind, shell.said)
    }

    fun encode(kind: String, said: List<Said>): String =
        "{\"kind\":${Json.write(kind)},\"said\":[\n" +
            said.joinToString(",\n") { Json.write(linkedMapOf("t" to it.t, "text" to it.text)) } +
            "\n]}"

    fun write(dir: File = File(DIR)) {
        dir.mkdirs()
        for ((kind, json) in all()) File(dir, "$kind.json").writeText(json + "\n")
    }

    class Shell(private val sc: ReplayScenarios.Scenario) {
        val said = ArrayList<Said>()

        val spokenExtras = ArrayList<Extra>()

        /** Where the goal (or the timed 5 km) was reached, as GoalCoach saw it. */
        var goalEnd: RecorderCore.StepEnd? = null
            private set

        /** Trace ms of the resume, when [run] had a kill. */
        var resumedAt: Long? = null
            private set

        val lines = ArrayList<JournalLine>()
        private val mode = sc.mode
        private val spec = sc.spec
        private var core = RecorderCore(mode, spec, config(sc.context?.cooperCurve))
        private var ticker = SampleTicker(wall = { 0L })
        private var coach = LiveCoach(sc.context, mode, spec)
        private var goal = GoalCoach(spec, sc.context)
        private var speech = SpeechClock()
        private var followUp = NudgeFollowUp()
        private var dispatch = LapDispatch(onLap = ::publishLap, onPhase = {}, onCue = ::publishCue)
        private var now = 0L
        private var coachPrevT = 0L
        private var coachPrevD = 0.0
        private var pressed = 0
        private var autoStopped = false

        private fun config(curve: List<Double>?) =
            RecorderCore.Config(volumeKeyLaps = false, cooperCurve = CooperCurve.fromFractions(curve) ?: CooperCurve.DEFAULT)

        fun run(kill: Kill? = null) {
            lines.add(JournalLine.Header(0, 0, "t4-${sc.kind}", "contract-fixture", "core-jvm-test", "UTC", mode, spec, Units.km))
            sc.context?.let { lines.add(JournalLine.LiveContextLine(0, 0, it)) }
            handle(core.start(0), 0)
            dispatch.ticked(0, 0.0)
            val hr = sc.hr.iterator()
            var next = if (hr.hasNext()) hr.next() else null
            for (f in sc.fixes) {
                val dark = kill != null && f.t >= kill.atMs && f.t < kill.atMs + kill.gapMs
                if (kill != null && !dark && f.t >= kill.atMs + kill.gapMs && resumedAt == null) resume(f.t, kill.gapMs)
                // HR items come first, as ReplaySource orders them; the dark span's are lost.
                while (next != null && next.t <= f.t) {
                    if (!dark) ticker.onHr(next)
                    next = if (hr.hasNext()) hr.next() else null
                }
                if (dark) continue
                now = f.t
                ticker.onFix(f)
                tick(f.t)
                if (autoStopped) break
            }
        }

        /** `RecordingSession.tick` in replay mode. */
        private fun tick(t: Long) {
            if (pressed < sc.presses.size && t >= sc.presses[pressed].atMs) {
                val out = when (sc.presses[pressed++].press) {
                    ReplayScenarios.Press.lap -> core.lap(LapSource.notification, t).second
                    ReplayScenarios.Press.startReps -> core.startReps(t).second
                    ReplayScenarios.Press.pause -> {
                        // As RecordingSession.pause (no T4 kind pauses today).
                        core.pause(t)
                        ticker.onPause()
                        followUp.cancel()
                        lines.add(JournalLine.Pause(t, t))
                        emptyList()
                    }
                }
                handle(out, t)
            }
            val samples = ticker.tick(t)
            lines.addAll(samples)
            dispatch.flush(t, ticker.distanceM)
            handle(core.tick(t, ticker.distanceM, !ticker.gpsLost(t)), t)
            dispatch.ticked(t, ticker.distanceM)
            coach.onTick(coachPrevT, coachPrevD, t, ticker.distanceM, samples.last().hr) { core.status(it).activeMs }
                ?.let { speakFire(null, it.base, it.fire, t, it.nudge) }
            coachPrevT = t
            coachPrevD = ticker.distanceM
            // A nudge follows its cue as its own line (`CuePlayer.dueNudge`): done only once said.
            followUp.due(now, speech.busyUntil)?.let { n ->
                speech.queued(now, CueComposer.words(n.text))
                said.add(Said(now, n.text))
                coach.nudgeSaid(n)
                lines.add(JournalLine.CueFired(t, t, JournalLine.FiredKind.nudge, n.rule, n.index, core.status(t).elapsedMs))
                spokenExtras.add(Extra(now, "nudge:${n.rule}#${n.index}"))
            }
        }

        /** Journaled in the core's order, sent with a step's end cue after its lap ([LapDispatch.ordered]). */
        private fun handle(out: List<RecorderCore.Output>, t: Long) {
            for (o in out) when (o) {
                is RecorderCore.Output.Lap -> lines.add(JournalLine.Lap(o.t, o.t, o.source))
                is RecorderCore.Output.Cue -> lines.add(JournalLine.Cue(o.t, o.t, o.kind))
                else -> Unit
            }
            for (o in LapDispatch.ordered(out)) when (o) {
                is RecorderCore.Output.Lap -> dispatch.lap(o, t, ticker.distanceM)
                is RecorderCore.Output.Cue -> dispatch.cue(o, hold = coach.holdsRepEndCues)
                is RecorderCore.Output.PhaseChanged -> dispatch.phase(o)
                is RecorderCore.Output.AutoStop -> autoStopped = true
            }
        }

        private fun publishLap(o: RecorderCore.Output.Lap, distanceM: Double) {
            coach.lapEnded(core.lapStep(o.index), distanceM, core.status(o.t).activeMs)
        }

        private fun publishCue(o: RecorderCore.Output.Cue) {
            goal.atCue(o.kind, core.phase, core.finalStepEnd)?.let { g ->
                goalEnd = core.finalStepEnd
                followUp.cancel()
                speech.queued(now, CueComposer.words(g.text))
                said.add(Said(now, g.text))
                if (spec?.isEvent != true) coach.goalReachedAt(g.distanceM, if (g.distanceGoal && g.goalValue % 1_000 == 0) g.timeMs else null)
            }
            val st = core.status(o.t)
            val next = if (st.stepRemainingM != null) null else st.phaseRemainingMs
            val fire = coach.atCue(o.kind, o.index, o.value, core.phase, core.stepIndex, st.phaseActiveMs, next)
            val base = CueWords.text(o.kind, o.value, spec, core.phase, core.repIndex, core.stepIndex, o.index)
            speakFire(o.kind, base, fire, o.t, coach.nudgeAtCue(o.kind, core.phase))
        }

        /** `RecordingSession.speakFire` + `CuePlayer.play`: a [nudge] waits to follow the cue. */
        private fun speakFire(kind: CueKind?, cueBase: String?, fire: LiveCoach.Fire?, t: Long, nudge: LiveCoach.Nudge?) {
            val extra = fire?.takeIf { it.speak }?.text
            val base = fire?.takeIf { it.speak }?.base ?: cueBase
            val composed = if (kind != null || base != null || extra != null) play(kind, base, extra, nudge) else null
            fire ?: return
            lines.add(JournalLine.CueFired(t, t, JournalLine.FiredKind.compare, fire.key, fire.index, core.status(t).elapsedMs))
            if (composed?.compareSpoken == true && extra != null) spokenExtras.add(Extra(now, "compare:${fire.key}#${fire.index}"))
        }

        private fun play(kind: CueKind?, text: String?, extra: String?, nudge: LiveCoach.Nudge?): CueComposer.Composed? {
            followUp.cancel()
            if (kind == CueKind.countdown) return null
            val fresh = speech.freshAt(now)
            val composed = CueComposer.compose(text, extra?.takeIf { fresh })
            val words = composed.text ?: return null
            speech.queued(now, CueComposer.words(words))
            said.add(Said(now, words))
            nudge?.let { followUp.offer(it, speech.busyUntil) }
            return composed
        }

        /** `RecordingSession.startResumed`: the gap line, then everything rebuilt from the journal; a new process, so a new speech queue. */
        private fun resume(t: Long, gapMs: Long) {
            resumedAt = t
            lines.add(JournalLine.Gap(t, t, gapMs))
            val replay = JournalReplay.read(lines.joinToString("") { JournalCodec.encode(it) + "\n" }.toByteArray())
            core = RecorderCore.restore(replay, t, config(replay.liveContext?.cooperCurve))
            ticker = SampleTicker(wall = { 0L })
            // Lap totals as startResumed seeds them: the journal's filtered distance at each lap marker, active time without gaps.
            val lapTotals = ArrayList<Pair<Double, Long>>()
            var inactive = 0L
            for (e in replay.events) when (e) {
                is RunEvent.Sample -> if (e.hasFix) ticker.filter.offer(LocationFix(e.t, e.lat!!, e.lon!!, e.altM, e.accuracyM!!, e.speedMps))
                is RunEvent.Gap -> inactive += e.endT - e.t
                is RunEvent.Lap -> lapTotals.add(ticker.filter.totalM to e.t - inactive)
                else -> Unit
            }
            ticker.filter.reanchor()
            dispatch = LapDispatch(onLap = ::publishLap, onPhase = {}, onCue = ::publishCue)
            dispatch.ticked(t, ticker.distanceM)
            coach = LiveCoach(replay.liveContext, mode, spec, replay.cuesFired).also {
                it.restoreReps(replay.events, core, lapTotals)
                it.resumeAt(ticker.distanceM)
            }
            goal = GoalCoach(spec, replay.liveContext).also { it.restored(reachedBeforeKill = core.finalStepEnd != null) }
            if (core.finalStepEnd != null) coach.goalReachedAt(ticker.distanceM, null)
            coachPrevT = t
            coachPrevD = ticker.distanceM
            speech = SpeechClock()
            followUp = NudgeFollowUp()
        }
    }
}
