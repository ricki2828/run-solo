package app.runsolo.core.record

import app.runsolo.core.ble.HrJoin
import app.runsolo.core.gps.PointFilter
import app.runsolo.core.journal.JournalLine
import app.runsolo.core.model.HrReading
import app.runsolo.core.model.LocationFix

/**
 * Owns the 1 Hz sample rule (plan §3/§4): on every tick, every fix that arrived since the last
 * tick is journaled in fix-time order (raw samples are always journaled, so acceptance is
 * repeatable); if none arrived, a no-fix tick carrying the current HR is journaled instead.
 * Either way a sample's `t` is `max(t, lastSampleT + 1)`, so journal order is time order even
 * when the provider delivers a fix late, after a no-fix tick was already written. Every fix
 * goes through [filter] (live distance for the tick stream); the finaliser recomputes the
 * same thing from the journaled raw samples.
 *
 * The service calls [onFix] from the location callback, [onHr] from the GATT callback and
 * [tick] from its 1 s timer (with the replay clock in replay mode).
 */
class SampleTicker(
    val filter: PointFilter = PointFilter(),
    val hrJoin: HrJoin = HrJoin(),
    private val wall: () -> Long = System::currentTimeMillis,
) {
    private val pending = ArrayList<LocationFix>()
    private var lastSampleT = Long.MIN_VALUE

    /** Cumulative accepted distance (metres) as of the last fix. */
    val distanceM: Double get() = filter.totalM

    /** Fixes delivered so late that they had to be re-stamped after a no-fix tick. */
    var restamped: Int = 0
        private set

    var lastFixT: Long? = null
        private set

    fun onFix(fix: LocationFix) {
        pending.add(fix)
        lastFixT = fix.t
    }

    fun onHr(reading: HrReading) = hrJoin.offer(reading)

    fun onHrNoContact() = hrJoin.offerNoContact()

    /** The samples for this tick, in time order; never empty (a tick without a fix is still a sample). */
    fun tick(nowT: Long): List<JournalLine.Sample> {
        val w = wall()
        val out = ArrayList<JournalLine.Sample>(1)
        if (pending.isEmpty()) {
            val t = if (nowT <= lastSampleT) lastSampleT + 1 else nowT
            out.add(JournalLine.Sample.noFix(t, w, hrJoin.hrAt(nowT)))
        } else {
            pending.sortBy { it.t }
            for (fix in pending) {
                filter.offer(fix)
                var t = fix.t
                if (t <= lastSampleT) {
                    t = lastSampleT + 1
                    restamped++
                }
                out.add(JournalLine.Sample(t, w, fix.lat, fix.lon, fix.altM, fix.accuracyM, fix.speedMps, hrJoin.hrAt(fix.t)))
                lastSampleT = t
            }
            pending.clear()
        }
        lastSampleT = out.last().t
        return out
    }

    /** True when no fix has arrived within [maxAgeMs] of [nowT] (drives `fault{gpsLost}`). */
    fun gpsLost(nowT: Long, maxAgeMs: Long = 5_000): Boolean = lastFixT?.let { nowT - it > maxAgeMs } ?: true
}
