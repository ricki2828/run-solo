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
import app.runsolo.R
import app.runsolo.core.model.Phase
import app.runsolo.core.model.RecorderState

/**
 * The recording notification (plan §3): elapsed as a chronometer (no per-second notify),
 * a countdown chronometer for timed steps, LAP as the primary action (also on the lock
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
        /** False in Free mode (plan §18.2): no LAP action at all, on the shade or the lock screen. */
        val lapAction: Boolean = true,
        /** Metres left in a distance step (the title shows them instead of a countdown). */
        val metresToGo: Double? = null,
        val cooper: Boolean = false,
    )

    fun build(c: Content): Notification {
        val title = title(c)
        val text = buildString {
            if (c.lapAction) append("Lap ${c.lapIndex + 1}") else append("Free run")
            c.hr?.let { append("  ·  $it bpm") }
        }
        val b = NotificationCompat.Builder(context, CHANNEL_ID)
            .setSmallIcon(R.drawable.ic_stat_runsupreme)
            .setColor(ARC)
            .setContentTitle(title)
            .setContentText(text)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setSilent(true)
            .setCategory(NotificationCompat.CATEGORY_SERVICE)
            .setVisibility(NotificationCompat.VISIBILITY_PUBLIC)
            .setForegroundServiceBehavior(NotificationCompat.FOREGROUND_SERVICE_IMMEDIATE)
            .setContentIntent(openApp())
        if (c.lapAction) b.addAction(0, "LAP", serviceAction(RecorderService.ACTION_LAP))
        b.addAction(0, if (c.state == RecorderState.paused) "Resume" else "Pause", serviceAction(if (c.state == RecorderState.paused) RecorderService.ACTION_RESUME else RecorderService.ACTION_PAUSE))
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

    /** "Rep 3/8 · 212 m to go" for a distance step; "Rep 3/10 · work" (the countdown ticks beside it) for a time step. */
    internal fun title(c: Content): String {
        val rep = "Rep ${c.repIndex}${c.reps?.let { "/$it" } ?: ""}"
        val toGo = c.metresToGo?.let { " · ${it.toInt()} m to go" }
        return when {
            c.state == RecorderState.paused -> "Paused"
            c.cooper && c.phase == Phase.work -> "12-minute test"
            c.phase == Phase.work -> rep + (toGo ?: " · work")
            c.phase == Phase.recovery -> "Recover" + (toGo ?: " · $rep")
            c.phase == Phase.warmup -> if (c.cooper) "Warm up · start the test when ready" else "Warm up · start reps when ready"
            c.phase == Phase.cooldown -> "Cool down"
            else -> "Recording"
        }
    }

    /** Momentary notification for a service start that has nothing to record. */
    fun buildIdle(): Notification = NotificationCompat.Builder(context, CHANNEL_ID)
        .setSmallIcon(R.drawable.ic_stat_runsupreme)
        .setColor(ARC)
        .setContentTitle("Run Supreme")
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
        /** Arc teal (brand accent) tints the small icon and actions, brief section 2.2. */
        const val ARC = 0xFF19E6FF.toInt()
    }
}
