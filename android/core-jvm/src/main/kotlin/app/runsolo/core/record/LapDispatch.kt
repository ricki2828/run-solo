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
 * A cue can be held with them too (LV1): a rep ended by a manual lap speaks its compare with the
 * cue that follows it, and that compare needs the rep's pace at the interpolated distance.
 *
 * The caller journals and speaks; this only decides the order and the lap's distance.
 */
class LapDispatch(
    private val onLap: (RecorderCore.Output.Lap, distanceM: Double) -> Unit,
    private val onPhase: (RecorderCore.Output.PhaseChanged) -> Unit,
    private val onCue: (RecorderCore.Output.Cue) -> Unit = {},
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

    /** A cue; [hold] = wait behind a pending manual lap (only when a compare needs its pace). */
    fun cue(o: RecorderCore.Output.Cue, hold: Boolean) {
        if (hold && pending.isNotEmpty()) pending.add(o) else onCue(o)
    }

    /** The tick at [t] has its sample in ([distanceM]): send what waited for it. Call before the core tick. */
    fun flush(t: Long, distanceM: Double) {
        if (pending.isEmpty()) return
        val out = ArrayList(pending)
        pending.clear()
        for (o in out) when (o) {
            is RecorderCore.Output.Lap -> onLap(o, interpolate(o.t, t, distanceM))
            is RecorderCore.Output.PhaseChanged -> onPhase(o)
            is RecorderCore.Output.Cue -> onCue(o)
            else -> Unit
        }
    }

    /**
     * The manual lap in [out] (a press just handed to [lap]), for the app to show at once while its
     * lap waits for the next tick (`LapPendingEvent`); null for an auto lap or no lap.
     * [lastLapActiveMs] is the active time at the last lap sent; [activeAt] the core's active time at
     * a time. The lap's active time starts at the previous lap, which may itself still wait here.
     */
    fun pressed(out: List<RecorderCore.Output>, lastLapActiveMs: Long, activeAt: (Long) -> Long): Pressed? {
        val lap = out.filterIsInstance<RecorderCore.Output.Lap>().firstOrNull() ?: return null
        if (lap.source == LapSource.auto) return null
        val prev = pending.filterIsInstance<RecorderCore.Output.Lap>().lastOrNull { it.index < lap.index }
        return Pressed(
            lap = lap,
            activeMs = activeAt(lap.t) - (prev?.let { activeAt(it.t) } ?: lastLapActiveMs),
            next = out.filterIsInstance<RecorderCore.Output.PhaseChanged>().firstOrNull(),
        )
    }

    /** A press as the app sees it: the lap, its active time, the phase it starts (structured only). */
    data class Pressed(val lap: RecorderCore.Output.Lap, val activeMs: Long, val next: RecorderCore.Output.PhaseChanged?)

    /** The tick (or start / resume) at [t] is done, at [distanceM]: the next press interpolates from here. */
    fun ticked(t: Long, distanceM: Double) {
        prevTickT = t
        prevTickD = distanceM
    }

    private fun interpolate(pressT: Long, t: Long, d: Double): Double =
        if (t <= prevTickT) d else prevTickD + (d - prevTickD) * ((pressT - prevTickT).toDouble() / (t - prevTickT)).coerceIn(0.0, 1.0)
}
