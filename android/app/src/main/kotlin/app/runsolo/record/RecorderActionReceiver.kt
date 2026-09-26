package app.runsolo.record

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.util.Log
import app.runsolo.core.model.LapSource

/**
 * Notification actions (LAP / Pause / Resume / Mute tips; "Stop" opens the app instead). A broadcast reaches the running process
 * directly and never starts the service, so a tap that arrives after the run ended (double
 * Stop, a queued LAP) is a harmless no-op instead of a `startForegroundService` start that
 * never reaches `startForeground` (ForegroundServiceDidNotStartInTimeException ~10 s later).
 */
class RecorderActionReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val session = RecorderService.session
        Log.i(TAG, "action ${intent.action} session=${session?.runId}")
        when (intent.action) {
            RecorderService.ACTION_LAP -> session?.lap(LapSource.notification)
            RecorderService.ACTION_PAUSE -> session?.pause()
            RecorderService.ACTION_RESUME -> session?.resume()
            // Older notifications still on screen after an update: pause, as the new "Stop" does.
            RecorderService.ACTION_STOP -> session?.pause()
            RecorderService.ACTION_MUTE_TIPS -> session?.muteTips()
        }
    }

    companion object {
        private const val TAG = "RunSolo/action"
    }
}
