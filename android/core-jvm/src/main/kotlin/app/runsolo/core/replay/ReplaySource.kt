package app.runsolo.core.replay

import app.runsolo.core.model.HrReading
import app.runsolo.core.model.LocationFix

/** Where the recorder takes fixes from — FLP/GPS in production, [ReplaySource] in replay mode. */
fun interface LocationSink {
    fun onLocation(fix: LocationFix)
}

fun interface HrSink {
    fun onHr(reading: HrReading)
}

/** Injectable timer so tests run a 45-minute trace instantly. Returns a cancel handle. */
fun interface Scheduler {
    fun schedule(delayMs: Long, action: () -> Unit): Cancellable
}

fun interface Cancellable {
    fun cancel()
}

/**
 * Feeds a fixture trace (+ optional HR stream) into the sinks at [speed]× real time (plan §12
 * GPS replay mode). **Time is virtual end to end**: every emitted item is stamped on the
 * trace timeline anchored at [start] (`tStart + (item.t − t0)`), and [now] reports the trace
 * time that corresponds to the current wall clock. In replay mode the service must use
 * [now] as the clock for `RecorderCore.tick`, the journal and `HrJoin`, so `PointFilter`
 * sees 1 s between 1 Hz fixes and phase timers run at trace speed: a 10× 4x4 auto-laps at
 * 4:00 of trace time, 24 s of wall time.
 *
 * Streams are merged in time order; a tie emits the location first.
 */
class ReplaySource(
    private val trace: List<LocationFix>,
    private val hr: List<HrReading> = emptyList(),
    private val speed: Double = 1.0,
    private val scheduler: Scheduler,
    private val clock: () -> Long,
    private val locationSink: LocationSink,
    private val hrSink: HrSink? = null,
) {
    init {
        require(speed > 0) { "speed must be positive" }
        require(trace.isNotEmpty()) { "empty trace" }
    }

    private sealed class Item(val t: Long) {
        class Loc(val fix: LocationFix) : Item(fix.t)
        class Hr(val r: HrReading) : Item(r.t)
    }

    private val items: List<Item> = (trace.map { Item.Loc(it) } + hr.map { Item.Hr(it) })
        .sortedWith(compareBy<Item> { it.t }.thenBy { if (it is Item.Loc) 0 else 1 })
    private var index = 0
    private var pending: Cancellable? = null
    private val t0 = items.first().t
    private var wallStart = 0L
    private var tStart = 0L

    var running = false
        private set
    var emitted = 0
        private set
    val total: Int get() = items.size

    /** Trace time now: the timeline the sinks' stamps live on. Valid after [start]. */
    fun now(): Long = tStart + ((clock() - wallStart) * speed).toLong()

    /** Trace time of the last item, on the [now] timeline. */
    val endT: Long get() = tStart + (items.last().t - t0)

    fun start() {
        check(!running)
        running = true
        index = 0
        wallStart = clock()
        tStart = wallStart
        scheduleNext()
    }

    fun stop() {
        running = false
        pending?.cancel()
        pending = null
    }

    private fun scheduleNext() {
        if (!running || index >= items.size) {
            running = false
            return
        }
        val item = items[index]
        val prevT = if (index == 0) t0 else items[index - 1].t
        val delay = ((item.t - prevT) / speed).toLong().coerceAtLeast(0)
        pending = scheduler.schedule(delay) {
            if (!running) return@schedule
            val stamp = tStart + (item.t - t0)
            when (item) {
                is Item.Loc -> locationSink.onLocation(item.fix.copy(t = stamp))
                is Item.Hr -> hrSink?.onHr(item.r.copy(t = stamp))
            }
            emitted++
            index++
            scheduleNext()
        }
    }
}
