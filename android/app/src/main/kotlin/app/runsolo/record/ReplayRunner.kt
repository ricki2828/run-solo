package app.runsolo.record

import android.content.Context
import android.os.Handler
import android.os.SystemClock
import app.runsolo.core.model.HrReading
import app.runsolo.core.model.LiveContext
import app.runsolo.core.model.LocationFix
import app.runsolo.core.model.SessionSpec
import app.runsolo.core.model.StepKind
import app.runsolo.core.replay.Cancellable
import app.runsolo.core.replay.ReplayScenarios
import app.runsolo.core.replay.ReplaySource
import app.runsolo.core.replay.Scheduler
import app.runsolo.core.replay.TraceFixture

/**
 * Replay mode (plan §12, debug builds only): a fixture trace fed through the recorder at
 * `speed`× on a virtual clock. The session uses [now] (the stamp of the last delivered item)
 * as its clock and ticks once per delivered fix, so `PointFilter`, the lap state machine and
 * the journal all run on trace time; wall time only paces delivery and a slow main thread
 * slows everything together.
 *
 * Fixtures: `synthetic-4x4` (straight line: 60 s warmup @2.5 m/s, the spec's steps
 * @4.2/2.0 m/s, 60 s cooldown, HR by phase), `kind:<kind>` (a [ReplayScenarios] scenario, I5:
 * the same trace and presses as the core-jvm `replay_<kind>.json` fixture) or `<name>` =
 * `assets/replay/<name>.csv`. The synthetic and kind fixtures press LAP (or START REPS) at the
 * end of the warmup so a hands-off replay exercises the auto-lap path.
 */
class ReplayRunner private constructor(
    private val fixes: List<LocationFix>,
    private val hr: List<HrReading>,
    private val speed: Double,
    /** Presses at trace times: a notification LAP or START REPS. */
    val presses: List<ReplayScenarios.ScriptedPress>,
    /** T4: a kind's own live compare context, used when the Start brings none. */
    val context: LiveContext? = null,
) {
    private var source: ReplaySource? = null

    /**
     * The session's Start stamp: trace time 0 maps here, so a step timed from Start (a time
     * goal, §G) ends at the same trace point as in the core-jvm fixture, however long the
     * service took to come up before [start].
     */
    private var anchorT: Long? = null

    /** Trace time; the anchor before [start]. */
    fun now(): Long = source?.now() ?: anchorT ?: SystemClock.elapsedRealtime()

    /** Called once at the session's Start with its first stamp. */
    fun anchorAt(t: Long) {
        anchorT = t
    }

    val endT: Long get() = source?.endT ?: 0

    /** Trace time (ms since the trace's first item) of the stamp [t]; what [presses] are keyed on. */
    fun traceMs(t: Long): Long = source?.let { t - it.startT } ?: 0
    val running: Boolean get() = source?.running == true

    /** Items are delivered on [handler]'s thread (the recorder thread). */
    fun start(handler: Handler, onFix: (LocationFix) -> Unit, onHr: (HrReading) -> Unit) {
        val scheduler = Scheduler { delayMs, action ->
            val r = Runnable { action() }
            handler.postDelayed(r, delayMs)
            Cancellable { handler.removeCallbacks(r) }
        }
        source = ReplaySource(
            trace = fixes,
            hr = hr,
            speed = speed,
            scheduler = scheduler,
            clock = { SystemClock.elapsedRealtime() },
            locationSink = { onFix(it) },
            hrSink = { onHr(it) },
        ).also { src -> anchorT?.let { src.start(it) } ?: src.start() }
    }

    fun stop() {
        source?.stop()
        source = null
    }

    companion object {
        const val SYNTHETIC_4X4 = "synthetic-4x4"
        const val KIND_PREFIX = "kind:"

        /** [spec]: the run's session; the synthetic trace follows its steps (the standard 4x4 when it has none). */
        fun create(context: Context, fixture: String, speed: Double, spec: SessionSpec?): ReplayRunner? {
            if (speed <= 0) return null
            if (fixture == SYNTHETIC_4X4) return synthetic4x4(spec?.takeIf { it.steps.isNotEmpty() } ?: SessionSpec.norwegian4x4(), speed)
            if (fixture.startsWith(KIND_PREFIX)) {
                val sc = ReplayScenarios.create(fixture.removePrefix(KIND_PREFIX)) ?: return null
                return ReplayRunner(sc.fixes, sc.hr, speed, sc.presses, sc.context)
            }
            if (!fixture.all { it.isLetterOrDigit() || it == '-' || it == '_' }) return null
            val text = try {
                context.assets.open("replay/$fixture.csv").bufferedReader().readText()
            } catch (_: Exception) {
                return null
            }
            val trace = TraceFixture.fromCsv(text)
            if (trace.fixes.isEmpty()) return null
            return ReplayRunner(trace.fixes, trace.hr, speed, emptyList())
        }

        private fun synthetic4x4(spec: SessionSpec, speed: Double): ReplayRunner {
            val segments = ArrayList<Pair<Int, Double>>()
            segments.add(60 to 2.5)
            // Time steps only (I1); a 0 s recovery adds nothing.
            for (st in spec.steps) if (st.value > 0) segments.add(st.value to if (st.kind == StepKind.work) 4.2 else 2.0)
            segments.add(60 to 2.5)
            val fixes = TraceFixture.straightLine(segments, accuracyM = 6.0, startT = 0)
            val hr = ArrayList<HrReading>()
            var t = 0L
            var bpm = 130
            for ((seconds, mps) in segments) {
                bpm = when {
                    mps > 4.0 -> 165
                    mps > 2.2 -> 130
                    else -> 145
                }
                repeat(seconds) {
                    t += 1000
                    hr.add(HrReading(t - 300, bpm + ((t / 1000) % 4).toInt()))
                }
            }
            return ReplayRunner(fixes, hr, speed, listOf(ReplayScenarios.ScriptedPress(60_000L, ReplayScenarios.Press.lap)))
        }
    }
}
