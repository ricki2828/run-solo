package app.runsolo.core.record

import app.runsolo.core.model.LapSource
import app.runsolo.core.model.Phase
import kotlin.test.Test
import kotlin.test.assertEquals

class LapDispatchTest {
    private val events = ArrayList<String>()
    private val dispatch = LapDispatch(
        onLap = { o, d -> events.add("lap${o.index}@${"%.1f".format(d)}") },
        onPhase = { events.add("phase ${it.phase}") },
    )

    private fun lap(i: Int, t: Long, source: LapSource) = RecorderCore.Output.Lap(i, t, source)
    private fun phase(t: Long, p: Phase) = RecorderCore.Output.PhaseChanged(t, p, 1, null)

    @Test
    fun `a manual lap and its phase change wait for the next tick, lap first, at the interpolated distance`() {
        dispatch.ticked(1_000, 10.0)
        dispatch.lap(lap(0, 1_250, LapSource.button), 10.0)
        dispatch.phase(phase(1_250, Phase.recovery))
        assertEquals(emptyList(), events)
        dispatch.flush(2_000, 14.0)
        assertEquals(listOf("lap0@11.0", "phase recovery"), events)
    }

    @Test
    fun `an auto lap and its phase change go out at once`() {
        dispatch.ticked(1_000, 10.0)
        dispatch.lap(lap(0, 1_600, LapSource.auto), 12.4)
        dispatch.phase(phase(1_600, Phase.work))
        assertEquals(listOf("lap0@12.4", "phase work"), events)
        dispatch.flush(2_000, 14.0)
        assertEquals(2, events.size)
    }
}
