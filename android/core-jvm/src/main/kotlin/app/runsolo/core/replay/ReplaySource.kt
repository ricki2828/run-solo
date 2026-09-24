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
 * GPS replay mode). Timestamps are rewritten to the injected [clock] at emission so the
 * recorder sees them exactly as it would see live fixes; the fixture's own `t` only sets the
 * spacing. Streams are merged in time order; a tie emits the location first.
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
    private var t0 = 0L

    var running = false
        private set
    var emitted = 0
        private set
    val total: Int get() = items.size

    fun start() {
        check(!running)
        running = true
        index = 0
        t0 = items.first().t
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
            val now = clock()
            when (item) {
                is Item.Loc -> locationSink.onLocation(item.fix.copy(t = now))
                is Item.Hr -> hrSink?.onHr(item.r.copy(t = now))
            }
            emitted++
            index++
            scheduleNext()
        }
    }
}
