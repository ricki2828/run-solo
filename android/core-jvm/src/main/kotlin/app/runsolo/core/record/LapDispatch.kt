package app.runsolo.core.record

import app.runsolo.core.model.LapSource

/**
 * When the live lap and phase events go out (PR #26 review P3), shared by `RecordingSession` and
 * the event-trace generator so the byte-for-byte trace proves the service's real ordering.
 *
 * Every lap's distance is the tick-stream total interpolated at the lap time, as the run file and
 * engine read it (BLOCK-2). An auto lap is emitted inside the tick that crossed its boundary, with
 * its time back-dated to the crossing, so it goes out at once at the distance interpolated between
 * the previous tick and this one. A manual lap (button, notification, volume key, START REPS) is
 * pressed between two ticks, so it waits for the next tick; the phase change it caused waits with
 * it, so the app always sees a lap before its phase change.
 *
 * The caller journals and speaks; this only decides the order and the lap's distance.
 */
class LapDispatch(
    private val onLap: (RecorderCore.Output.Lap, distanceM: Double) -> Unit,
    private val onPhase: (RecorderCore.Output.PhaseChanged) -> Unit,
) {
    private val pending = ArrayList<RecorderCore.Output>()
    private var prevTickT = 0L
    private var prevTickD = 0.0

    /** A lap from the core, during the tick (or press) at [t] with the ticker at [distanceM]. */
    fun lap(o: RecorderCore.Output.Lap, t: Long, distanceM: Double) {
        if (o.source == LapSource.auto) onLap(o, interpolate(o.t, t, distanceM)) else pending.add(o)
    }

    fun phase(o: RecorderCore.Output.PhaseChanged) {
        if (pending.isEmpty()) onPhase(o) else pending.add(o)
    }

    /** The tick at [t] has its sample in ([distanceM]): send what waited for it. Call before the core tick. */
    fun flush(t: Long, distanceM: Double) {
        if (pending.isEmpty()) return
        val out = ArrayList(pending)
        pending.clear()
        for (o in out) when (o) {
            is RecorderCore.Output.Lap -> onLap(o, interpolate(o.t, t, distanceM))
            is RecorderCore.Output.PhaseChanged -> onPhase(o)
            else -> Unit
        }
    }

    /** The tick (or start / resume) at [t] is done, at [distanceM]: the next press interpolates from here. */
    fun ticked(t: Long, distanceM: Double) {
        prevTickT = t
        prevTickD = distanceM
    }

    private fun interpolate(pressT: Long, t: Long, d: Double): Double =
        if (t <= prevTickT) d else prevTickD + (d - prevTickD) * ((pressT - prevTickT).toDouble() / (t - prevTickT)).coerceIn(0.0, 1.0)
}
