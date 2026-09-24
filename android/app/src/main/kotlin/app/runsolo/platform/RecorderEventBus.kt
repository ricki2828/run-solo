package app.runsolo.platform

import android.os.Handler
import android.os.Looper
import app.runsolo.record.RecorderService

/**
 * The one EventChannel listener (plan §2): Dart subscribes once and exposes a broadcast
 * stream. Every event is posted to the main looper — also when emitted on main — so Dart
 * receives them in emission order (a synchronous delivery could overtake an earlier posted
 * one: a stale "recording" tick after IDLE). When nobody listens (Flutter killed, recorder
 * still running) they are dropped — `status()` is the source of truth for a recreated UI.
 * Debug builds also log every event through [EventTrace]; the elapsed time and the status
 * snapshot for state/phase events are taken at emission (the caller holds the session
 * monitor), never at delivery, so the CI trace check cannot flake on a busy main thread.
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
        val session = RecorderService.session ?: RecorderService.pending
        val elapsed = session?.elapsedNowMs() ?: 0L
        val snapshot = if (EventTrace.enabled && (event is StateEvent || event is PhaseEvent)) session?.status() else null
        main.post {
            sink?.success(event)
            EventTrace.event(event, elapsed)
            if (snapshot != null) EventTrace.status(snapshot, elapsed)
        }
    }
}
