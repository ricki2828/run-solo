package app.runsolo.platform

import android.os.Handler
import android.os.Looper

/**
 * The one EventChannel listener (plan §2): Dart subscribes once and exposes a broadcast
 * stream. Events are delivered on the main thread; when nobody listens (Flutter killed,
 * recorder still running) they are dropped — `status()` is the source of truth for a
 * recreated UI, not the event history.
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
            sink?.success(event)
        } else {
            main.post { sink?.success(event) }
        }
    }
}
