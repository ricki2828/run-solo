package app.runsolo.core.record

import app.runsolo.core.model.CueKind
import app.runsolo.core.model.LapSource
import app.runsolo.core.model.Phase
import kotlin.test.Test
import kotlin.test.assertEquals

class LapDispatchTest {
    private val events = ArrayList<String>()
    private val dispatch = LapDispatch(
        onLap = { o, d -> events.add("lap${o.index}@${"%.1f".format(d)}") },
        onPhase = { events.add("phase ${it.phase}") },
        onCue = { events.add("cue ${it.kind}") },
    )

    private fun lap(i: Int, t: Long, source: LapSource) = RecorderCore.Output.Lap(i, t, source)
    private fun phase(t: Long, p: Phase) = RecorderCore.Output.PhaseChanged(t, p, 1, null)

    @Test
    fun `a manual lap and its phase change wait for the next tick, lap first, at the interpolated distance`() {
        dispatch.ticked(1_000, 10.0)
        dispatch.lap(lap(0, 1_250, LapSource.button), 1_250, 10.0)
        dispatch.phase(phase(1_250, Phase.recovery))
        assertEquals(emptyList(), events)
        dispatch.flush(2_000, 14.0)
        assertEquals(listOf("lap0@11.0", "phase recovery"), events)
    }

    @Test
    fun `an auto lap and its phase change go out at once, the lap at its back-dated crossing`() {
        dispatch.ticked(1_000, 10.0)
        dispatch.lap(lap(0, 1_600, LapSource.auto), 2_000, 14.0) // crossed 60% into the tick
        dispatch.phase(phase(1_600, Phase.work))
        assertEquals(listOf("lap0@12.4", "phase work"), events)
        dispatch.flush(2_000, 14.0)
        assertEquals(2, events.size)
    }

    @Test
    fun `pressed - a manual lap with the phase it starts, active time from the previous lap still waiting`() {
        val active = { t: Long -> t - 100 } // 100 ms paused before anything here
        dispatch.ticked(1_000, 10.0)
        val a = lap(0, 1_250, LapSource.button)
        dispatch.lap(a, 1_250, 10.0)
        val next = phase(1_250, Phase.work)
        dispatch.phase(next)
        val p0 = dispatch.pressed(listOf(a, next), lastLapActiveMs = 0, activeAt = active)!!
        assertEquals(a, p0.lap)
        assertEquals(1_150L, p0.activeMs)
        assertEquals(next, p0.next)
        // A second press before the tick: its active time starts at the first, not the last sent lap.
        val b = lap(1, 1_900, LapSource.notification)
        dispatch.lap(b, 1_900, 10.0)
        assertEquals(650L, dispatch.pressed(listOf(b), lastLapActiveMs = 0, activeAt = active)!!.activeMs)
        // An auto lap is not a press.
        assertEquals(null, dispatch.pressed(listOf(lap(2, 2_000, LapSource.auto)), 0, active))
        assertEquals(null, dispatch.pressed(emptyList(), 0, active))
    }

    @Test
    fun `a held cue waits behind a pending manual lap, an unheld one goes at once`() {
        dispatch.ticked(1_000, 10.0)
        dispatch.lap(lap(1, 1_250, LapSource.button), 1_250, 10.0)
        dispatch.phase(phase(1_250, Phase.recovery))
        dispatch.cue(RecorderCore.Output.Cue(1_250, CueKind.halfway), hold = false)
        dispatch.cue(RecorderCore.Output.Cue(1_250, CueKind.start), hold = true)
        assertEquals(listOf("cue halfway"), events)
        dispatch.flush(2_000, 14.0)
        assertEquals(listOf("cue halfway", "lap1@11.0", "phase recovery", "cue start"), events)
        dispatch.cue(RecorderCore.Output.Cue(2_000, CueKind.halfway), hold = true)
        assertEquals("cue halfway", events.last(), "nothing pending: a held cue goes at once")
    }
}
