package app.runsolo.record

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.os.SystemClock
import androidx.core.app.NotificationCompat
import app.runsolo.MainActivity
import app.runsolo.core.model.Phase
import app.runsolo.core.model.RecorderState

/**
 * The recording notification (plan §3): elapsed as a chronometer (no per-second notify),
 * a countdown chronometer for preset phases, LAP as the primary action (also on the lock
 * screen), Stop second. On 14+ the user can swipe it away; the in-app button remains.
 */
class RecorderNotification(private val context: Context) {
    private val manager = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager

    fun createChannel() {
        val channel = NotificationChannel(CHANNEL_ID, "Recording", NotificationManager.IMPORTANCE_LOW).apply {
            description = "Shown while a run is being recorded"
            setShowBadge(false)
            lockscreenVisibility = Notification.VISIBILITY_PUBLIC
        }
        manager.createNotificationChannel(channel)
    }

    data class Content(
        val state: RecorderState,
        val phase: Phase,
        val repIndex: Int,
        val reps: Int?,
        /** elapsedRealtime at which the elapsed chronometer started (wall time of the run start, minus pauses). */
        val elapsedBaseRealtime: Long,
        /** Remaining ms of the current timed phase, or null for untimed phases. */
        val phaseRemainingMs: Long?,
        val lapIndex: Int,
        val hr: Int?,
    )

    fun build(c: Content): Notification {
        val title = when {
            c.state == RecorderState.paused -> "Paused"
            c.phase == Phase.work -> "Rep ${c.repIndex}${c.reps?.let { " of $it" } ?: ""} — work"
            c.phase == Phase.recovery -> "Rep ${c.repIndex}${c.reps?.let { " of $it" } ?: ""} — recover"
            c.phase == Phase.warmup -> "Warm up — press LAP to start rep 1"
            c.phase == Phase.cooldown -> "Cool down"
            else -> "Recording"
        }
        val text = buildString {
            append("Lap ${c.lapIndex + 1}")
            c.hr?.let { append("  ·  $it bpm") }
        }
        val b = NotificationCompat.Builder(context, CHANNEL_ID)
            .setSmallIcon(android.R.drawable.ic_media_play)
            .setContentTitle(title)
            .setContentText(text)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setSilent(true)
            .setCategory(NotificationCompat.CATEGORY_SERVICE)
            .setVisibility(NotificationCompat.VISIBILITY_PUBLIC)
            .setForegroundServiceBehavior(NotificationCompat.FOREGROUND_SERVICE_IMMEDIATE)
            .setContentIntent(openApp())
            .addAction(0, "LAP", serviceAction(RecorderService.ACTION_LAP))
            .addAction(0, if (c.state == RecorderState.paused) "Resume" else "Pause", serviceAction(if (c.state == RecorderState.paused) RecorderService.ACTION_RESUME else RecorderService.ACTION_PAUSE))
            .addAction(0, "Stop", serviceAction(RecorderService.ACTION_STOP))
        if (c.state == RecorderState.paused) {
            b.setUsesChronometer(false)
        } else if (c.phaseRemainingMs != null) {
            // Count down to the phase boundary; the notification's clock is wall time.
            val endWall = System.currentTimeMillis() + c.phaseRemainingMs
            b.setUsesChronometer(true).setChronometerCountDown(true).setWhen(endWall).setShowWhen(true)
        } else {
            val startWall = System.currentTimeMillis() - (SystemClock.elapsedRealtime() - c.elapsedBaseRealtime)
            b.setUsesChronometer(true).setWhen(startWall).setShowWhen(true)
        }
        return b.build()
    }

    fun update(c: Content) = manager.notify(NOTIFICATION_ID, build(c))

    /** Momentary notification for a service start that has nothing to record. */
    fun buildIdle(): Notification = NotificationCompat.Builder(context, CHANNEL_ID)
        .setSmallIcon(android.R.drawable.ic_media_play)
        .setContentTitle("Run Solo")
        .setSilent(true)
        .setForegroundServiceBehavior(NotificationCompat.FOREGROUND_SERVICE_IMMEDIATE)
        .build()

    private fun openApp(): PendingIntent {
        val i = Intent(context, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP)
        return PendingIntent.getActivity(context, 0, i, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
    }

    /** Broadcast to [RecorderActionReceiver]: reaches the running process, never starts the service. */
    private fun serviceAction(action: String): PendingIntent {
        val i = Intent(context, RecorderActionReceiver::class.java).setAction(action)
        return PendingIntent.getBroadcast(context, action.hashCode(), i, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
    }

    companion object {
        const val CHANNEL_ID = "recording"
        const val NOTIFICATION_ID = 1001
    }
}
