package app.runsolo.record

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.media.AudioManager
import android.media.VolumeProvider
import android.media.session.MediaSession
import android.media.session.PlaybackState
import android.os.SystemClock
import android.util.Log
import androidx.core.content.ContextCompat

/**
 * Volume-key LAP (plan §3, W8): opt-in, on by default only in Laps mode (never in Free, which
 * takes no laps at all). Two paths, one debounce:
 *
 *  1. An active MediaSession with a remote [VolumeProvider]: while it is the system's volume
 *     target the keys come here and never touch the music volume (API 29, 35+ verified on
 *     the CI emulators).
 *  2. Android 14 (API 34) only routes volume keys to a remote session that owns a
 *     MediaRouter2 routing session ("has a remote media session but no associated routing
 *     session"), which a non-casting app never has, so the key adjusts a stream instead. The
 *     [VOLUME_CHANGED_ACTION] receiver treats that change as the press, laps, and puts the
 *     stream back where it was (a one-step blip, net unchanged). Known limit: at the top or
 *     bottom of the range that key changes nothing and no lap lands; the other key still works.
 *
 * Known limit of both: with another player active (Spotify) the keys go to that session; the
 * notification LAP stays primary. 400 ms debounce here, again in the core.
 */
class LapInput(context: Context, private val onLap: () -> Unit) {
    private val context = context.applicationContext
    private val audio = this.context.getSystemService(Context.AUDIO_SERVICE) as AudioManager
    private var session: MediaSession? = null
    private var receiver: BroadcastReceiver? = null
    private var lastPressT = 0L

    /** Broadcasts caused by our own restore are ignored until this time. */
    private var suppressUntil = 0L

    private fun press(source: String): Boolean {
        val now = SystemClock.elapsedRealtime()
        if (now - lastPressT < DEBOUNCE_MS) return false
        lastPressT = now
        Log.i(TAG, "lap from $source")
        onLap()
        return true
    }

    fun enable() {
        if (session != null) return
        val s = MediaSession(context, "RunSolo lap")
        s.setCallback(object : MediaSession.Callback() {})
        s.setPlaybackState(
            PlaybackState.Builder()
                .setActions(PlaybackState.ACTION_PLAY or PlaybackState.ACTION_PAUSE)
                .setState(PlaybackState.STATE_PLAYING, 0, 1f, SystemClock.elapsedRealtime())
                .build(),
        )
        s.setPlaybackToRemote(object : VolumeProvider(VolumeProvider.VOLUME_CONTROL_RELATIVE, 50, 50) {
            override fun onAdjustVolume(direction: Int) {
                Log.i(TAG, "volume key direction=$direction")
                if (direction == AudioManager.ADJUST_SAME) return
                press("session")
            }
        })
        s.isActive = true
        session = s
        val r = object : BroadcastReceiver() {
            override fun onReceive(c: Context, intent: Intent) {
                if (intent.action != VOLUME_CHANGED_ACTION) return
                val stream = intent.getIntExtra(EXTRA_STREAM_TYPE, -1)
                val value = intent.getIntExtra(EXTRA_STREAM_VALUE, -1)
                val prev = intent.getIntExtra(EXTRA_PREV_STREAM_VALUE, value)
                if (stream < 0 || value < 0 || value == prev) return
                if (SystemClock.elapsedRealtime() < suppressUntil) return
                Log.i(TAG, "volume changed stream=$stream $prev→$value (session not the key target; fallback)")
                if (!press("stream")) return
                // Put the user's volume back; the resulting broadcast is ours and is ignored.
                suppressUntil = SystemClock.elapsedRealtime() + RESTORE_SUPPRESS_MS
                try {
                    audio.setStreamVolume(stream, prev, 0)
                } catch (e: Exception) {
                    Log.w(TAG, "volume restore failed: $e")
                }
            }
        }
        ContextCompat.registerReceiver(context, r, IntentFilter(VOLUME_CHANGED_ACTION), ContextCompat.RECEIVER_EXPORTED)
        receiver = r
        Log.i(TAG, "volume-key lap enabled")
    }

    fun disable() {
        session?.let {
            it.isActive = false
            it.release()
        }
        session = null
        receiver?.let {
            try {
                context.unregisterReceiver(it)
            } catch (_: Exception) {
            }
        }
        receiver = null
    }

    companion object {
        private const val TAG = "RunSolo/lapinput"
        private const val DEBOUNCE_MS = 400L
        private const val RESTORE_SUPPRESS_MS = 500L

        // AudioManager's broadcast for any stream volume change (public action string, extras @hide).
        private const val VOLUME_CHANGED_ACTION = "android.media.VOLUME_CHANGED_ACTION"
        private const val EXTRA_STREAM_TYPE = "android.media.EXTRA_VOLUME_STREAM_TYPE"
        private const val EXTRA_STREAM_VALUE = "android.media.EXTRA_VOLUME_STREAM_VALUE"
        private const val EXTRA_PREV_STREAM_VALUE = "android.media.EXTRA_PREV_VOLUME_STREAM_VALUE"
    }
}
