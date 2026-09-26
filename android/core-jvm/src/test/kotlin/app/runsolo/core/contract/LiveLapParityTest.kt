package app.runsolo.core.contract

import app.runsolo.core.json.Json
import app.runsolo.core.json.list
import app.runsolo.core.record.LapDispatch
import app.runsolo.core.record.RecorderCore
import app.runsolo.core.record.SampleTicker
import app.runsolo.core.replay.ReplayScenarios
import kotlin.math.abs
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

/**
 * BLOCK-2 parity for every session kind: each live LapEvent distance (the service's
 * [LapDispatch], auto laps back-dated inside a tick, manual laps at the next tick) equals the
 * run file's lap boundary from the same trace to 0.1 m. The distance kinds (400s, Yasso, 1 km,
 * parkrun) cross their boundaries between ticks, which the 4x4 event trace never does.
 */
class LiveLapParityTest {
    private fun liveLaps(kind: String): List<Double> {
        val sc = ReplayScenarios.create(kind)!!
        val core = RecorderCore(sc.mode, sc.spec)
        val ticker = SampleTicker(wall = { 0L })
        val live = ArrayList<Double>()
        val dispatch = LapDispatch(onLap = { _, d -> live.add(d) }, onPhase = {})
        var t = 0L
        fun dispatchAll(out: List<RecorderCore.Output>) {
            for (o in out) when (o) {
                is RecorderCore.Output.Lap -> dispatch.lap(o, t, ticker.distanceM)
                is RecorderCore.Output.PhaseChanged -> dispatch.phase(o)
                else -> Unit
            }
        }
        val driver = ReplayScenarios.Driver(
            core, ticker, sc.presses,
            // As RecordingSession.tick: the sample is in, then what waited for it goes out.
            onSamples = { dispatch.flush(t, ticker.distanceM) },
            onOutputs = { dispatchAll(it) },
        )
        dispatchAll(core.start(0))
        dispatch.ticked(0, 0.0)
        val hr = sc.hr.iterator()
        var next = if (hr.hasNext()) hr.next() else null
        for (f in sc.fixes) {
            t = f.t
            while (next != null && next.t <= f.t) {
                ticker.onHr(next)
                next = if (hr.hasNext()) hr.next() else null
            }
            val out = driver.step(f, null)
            dispatch.ticked(t, ticker.distanceM)
            if (out.any { it is RecorderCore.Output.AutoStop }) break
        }
        return live
    }

    @Test
    fun `every live lap distance equals the run file's lap boundary, every kind`() {
        for (kind in ReplayScenarios.KINDS) {
            val file = Json.parseObject(ContractFixtures.all().getValue("replay_${kind.replace('-', '_')}"))
            val boundaries = file.list("laps").map { ((it as Map<*, *>)["d1"] as Number).toDouble() }.dropLast(1) // the last lap ends at stop
            val live = liveLaps(kind)
            assertEquals(boundaries.size, live.size, "$kind: live laps $live vs file $boundaries")
            for ((i, pair) in live.zip(boundaries).withIndex()) {
                assertTrue(abs(pair.first - pair.second) <= 0.1, "$kind lap $i: live ${pair.first} m, file ${pair.second} m")
            }
        }
    }
}
