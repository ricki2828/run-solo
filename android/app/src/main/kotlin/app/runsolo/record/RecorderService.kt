package app.runsolo.record

import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.IBinder
import android.os.PowerManager
import android.util.Log
import androidx.core.app.ServiceCompat
import app.runsolo.core.model.LapSource
import app.runsolo.platform.FaultEvent
import app.runsolo.platform.FaultKind
import app.runsolo.platform.RecorderEventBus

/**
 * The foreground service that owns a run (plan §3, B2): `foregroundServiceType="location"`,
 * `START_NOT_STICKY`, started only from the visible Activity via [RecorderApiImpl] — a sticky
 * restart from the background would throw on Android 14+, so recovery happens on app open.
 *
 * The [RecordingSession] is created by the Activity before the service starts (so `start`
 * can return the run id synchronously) and handed over through [pending]; the service
 * supplies the foreground notification, the wake lock and the sensors, and finalises on Stop.
 */
class RecorderService : Service() {
    private var wakeLock: PowerManager.WakeLock? = null
    private lateinit var notification: RecorderNotification

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        notification = RecorderNotification(this).also { it.createChannel() }
        instance = this
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_START -> startRun()
            ACTION_LAP -> session?.lap(LapSource.notification)
            ACTION_PAUSE -> session?.pause()
            ACTION_RESUME -> session?.resume()
            ACTION_STOP -> stopRun()
            else -> if (session == null) stopSelf()
        }
        return START_NOT_STICKY
    }

    private fun startRun() {
        val s = pending ?: session
        pending = null
        if (s == null) {
            Log.w(TAG, "ACTION_START with no session")
            stopSelf()
            return
        }
        session = s
        s.onNotificationChanged = { refreshNotification() }
        s.onReplayFinished = { stopRun() }
        try {
            ServiceCompat.startForeground(
                this,
                RecorderNotification.NOTIFICATION_ID,
                notification.build(s.notificationContent()),
                ServiceInfo.FOREGROUND_SERVICE_TYPE_LOCATION,
            )
        } catch (e: Exception) {
            // Android 14+: location FGS refused (permission revoked between check and start, or
            // started from the background). The run cannot continue without it.
            Log.e(TAG, "startForeground failed", e)
            RecorderEventBus.emit(FaultEvent(kind = FaultKind.LOW_STORAGE, message = "Could not start recording: ${e.message}"))
            stopRun()
            return
        }
        val pm = getSystemService(Context.POWER_SERVICE) as PowerManager
        wakeLock = pm.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "runsolo:record").also { it.acquire() }
        val prefs = getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        s.attachSensors(
            preferRawGps = prefs.getBoolean(PREF_RAW_GPS, false),
            cuesEnabled = prefs.getBoolean(PREF_CUES, true),
        )
        Log.i(TAG, "recording ${s.runId} replay=${s.isReplay}")
    }

    private fun refreshNotification() {
        val s = session ?: return
        try {
            notification.update(s.notificationContent())
        } catch (e: Exception) {
            Log.w(TAG, "notification update failed: $e")
        }
    }

    /** Stop → finalise (journal → run file) → drop the foreground state. Idempotent. */
    fun stopRun(): String? {
        val s = session ?: return null
        session = null
        val path = s.stop()
        wakeLock?.let { if (it.isHeld) it.release() }
        wakeLock = null
        ServiceCompat.stopForeground(this, ServiceCompat.STOP_FOREGROUND_REMOVE)
        stopSelf()
        return path
    }

    override fun onDestroy() {
        // Normally after stopRun. If the system tears the service down while a run is on, the
        // journal is intact on disk: sensors stop, the session stays for status()/stop(), and
        // recover() handles the rest after a process death.
        session?.detachSensors()
        wakeLock?.let { if (it.isHeld) it.release() }
        wakeLock = null
        if (instance === this) instance = null
        super.onDestroy()
    }

    companion object {
        const val TAG = "RunSolo/service"
        const val ACTION_START = "app.runsolo.action.START"
        const val ACTION_LAP = "app.runsolo.action.LAP"
        const val ACTION_PAUSE = "app.runsolo.action.PAUSE"
        const val ACTION_RESUME = "app.runsolo.action.RESUME"
        const val ACTION_STOP = "app.runsolo.action.STOP"
        const val PREFS = "runsolo.settings"
        const val PREF_RAW_GPS = "rawGps"
        const val PREF_CUES = "cues"
        const val PREF_VOLUME_KEY_LAPS = "volumeKeyLaps"

        /** Session handed from the Activity to the service on ACTION_START. Main thread only. */
        @Volatile
        var pending: RecordingSession? = null

        /** The run in progress, if any. Main thread only. */
        @Volatile
        var session: RecordingSession? = null

        @Volatile
        var instance: RecorderService? = null
    }
}
