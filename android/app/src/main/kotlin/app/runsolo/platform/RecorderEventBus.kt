package app.runsolo.platform

import android.os.Handler
import android.os.Looper
import app.runsolo.record.RecorderService

/**
 * The one EventChannel listener (plan §2): Dart subscribes once and exposes a broadcast
 * stream. Events are delivered on the main thread; when nobody listens (Flutter killed,
 * recorder still running) they are dropped — `status()` is the source of truth for a
 * recreated UI, not the event history. Debug builds also log every event (and a status
 * snapshot after state/phase events) through [EventTrace].
 */
object RecorderEventBus : RecorderEventsStreamHandler() {
    private val main = Handler(Looper.getMainLooper())
    private var sink: PigeonEventSink<RecorderEvent>? = null

    override fun onListen(p0: Any?, sink: PigeonEventSink<RecorderEvent>) {
        this.sink = sink
    }

    override fun onCancel(p0: Any?) {
        sink = null
    }

    fun emit(event: RecorderEvent) {
        if (Looper.myLooper() == Looper.getMainLooper()) {
            deliver(event)
        } else {
            main.post { deliver(event) }
        }
    }

    private fun deliver(event: RecorderEvent) {
        sink?.success(event)
        val session = RecorderService.session ?: RecorderService.pending
        val elapsed = session?.elapsedNowMs() ?: 0L
        EventTrace.event(event, elapsed)
        if ((event is StateEvent || event is PhaseEvent) && session != null) EventTrace.status(session.status(), elapsed)
    }
}
