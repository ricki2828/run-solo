package app.runsolo.record

import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.util.Log
import app.runsolo.core.model.LocationFix
import app.runsolo.platform.GpsProbeEvent

/**
 * Location readiness before Start (the event run's Start button waits for "GPS ready"): while
 * the Start screen is open the app asks for fixes with the recording's own provider settings and
 * gets a [GpsProbeEvent] about once a second, with the current position (the app picks the event
 * course by its nearest known start; kept in memory only, nothing is written until a run records). Foreground only, no service: it stops when the
 * screen closes, the app leaves the foreground, or a run starts, so it never drains the battery
 * in the background. Without location permission it reports no fix and asks for nothing.
 * Main thread only.
 */
class GpsProbe(
    private val hasPermission: () -> Boolean,
    private val source: () -> LocationSource,
    private val emit: (GpsProbeEvent) -> Unit,
    private val clock: () -> Long = { SystemClock.elapsedRealtime() },
    private val handler: Handler = Handler(Looper.getMainLooper()),
) {
    private var src: LocationSource? = null
    private var last: LocationFix? = null
    private var lastAtMs: Long? = null
    private var ticking = false

    val running: Boolean get() = ticking

    private val tick = object : Runnable {
        override fun run() {
            if (!ticking) return
            emit(event())
            handler.postDelayed(this, PERIOD_MS)
        }
    }

    /** Idempotent: a second start keeps the one request. */
    fun start() {
        if (ticking) return
        ticking = true
        if (hasPermission()) {
            try {
                src = source().also { it.start(handler.looper) { fix -> last = fix; lastAtMs = clock() } }
            } catch (e: Exception) {
                Log.w(TAG, "probe location start failed: $e")
                src = null
            }
        }
        Log.i(TAG, "gps probe on (source=${src != null})")
        handler.post(tick)
    }

    /** Idempotent; also called when a run starts and when the app leaves the foreground. */
    fun stop() {
        if (!ticking) return
        ticking = false
        handler.removeCallbacks(tick)
        src?.stop()
        src = null
        last = null
        lastAtMs = null
        Log.i(TAG, "gps probe off")
    }

    /** A fix within the last [FRESH_MS] counts; its accuracy and age go with it. */
    internal fun event(): GpsProbeEvent {
        val at = lastAtMs
        val age = at?.let { clock() - it }
        val fresh = age != null && age <= FRESH_MS
        val f = last.takeIf { fresh }
        return GpsProbeEvent(fix = fresh, lat = f?.lat, lon = f?.lon, accuracyM = f?.accuracyM, fixAgeMs = age)
    }

    companion object {
        const val TAG = "RunSolo/probe"
        const val PERIOD_MS = 1_000L
        const val FRESH_MS = 5_000L
    }
}
