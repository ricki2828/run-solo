package app.runsolo.record

import android.content.Context
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import app.runsolo.core.model.HrReading
import app.runsolo.core.model.LocationFix
import app.runsolo.core.model.Preset
import app.runsolo.core.replay.Cancellable
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
 * Fixtures: `synthetic-4x4` (straight line: 60 s warmup @2.5 m/s, the preset's reps
 * @4.2/2.0 m/s, 60 s cooldown, HR by phase) or `<name>` = `assets/replay/<name>.csv`.
 * The synthetic fixture also presses LAP at the end of the warmup so a hands-off replay
 * exercises the auto-lap path.
 */
class ReplayRunner private constructor(
    private val fixes: List<LocationFix>,
    private val hr: List<HrReading>,
    private val speed: Double,
    /** Trace-time offsets (ms from the first fix) at which a notification LAP is pressed. */
    val autoLapAtMs: List<Long>,
) {
    private val handler = Handler(Looper.getMainLooper())
    private var source: ReplaySource? = null

    /** Trace time; valid after [start]. */
    fun now(): Long = source?.now() ?: SystemClock.elapsedRealtime()

    val endT: Long get() = source?.endT ?: 0
    val running: Boolean get() = source?.running == true

    fun start(onFix: (LocationFix) -> Unit, onHr: (HrReading) -> Unit) {
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
        ).also { it.start() }
    }

    fun stop() {
        source?.stop()
        source = null
    }

    companion object {
        const val SYNTHETIC_4X4 = "synthetic-4x4"

        fun create(context: Context, fixture: String, speed: Double, preset: Preset?): ReplayRunner? {
            if (speed <= 0) return null
            if (fixture == SYNTHETIC_4X4) return synthetic4x4(preset ?: Preset.DEFAULT_4X4, speed)
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

        private fun synthetic4x4(preset: Preset, speed: Double): ReplayRunner {
            val segments = ArrayList<Pair<Int, Double>>()
            segments.add(60 to 2.5)
            repeat(preset.reps) { segments.add(preset.workSeconds to 4.2); segments.add(preset.recoverySeconds to 2.0) }
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
            return ReplayRunner(fixes, hr, speed, autoLapAtMs = listOf(60_000L))
        }
    }
}
