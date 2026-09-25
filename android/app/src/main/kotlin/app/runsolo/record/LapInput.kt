package app.runsolo.record

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.media.AudioDeviceCallback
import android.media.AudioDeviceInfo
import android.media.AudioManager
import android.media.VolumeProvider
import android.media.session.MediaSession
import android.media.session.PlaybackState
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.util.Log
import androidx.core.content.ContextCompat

/**
 * Volume-key LAP (plan §3, W8): opt-in, on by default only in Laps mode (never in Free, which
 * takes no laps at all). Two paths, one debounce:
 *
 *  1. An active MediaSession with a remote [VolumeProvider]: while it is the system's volume
 *     target the keys come here and never touch the music volume (API 29 and 36 verified on
 *     the CI emulators; this is the only path on every API but 34).
 *  2. Android 14 (API 34) routes volume keys to a remote session only when the app owns a
 *     MediaRouter2 routing session ("has a remote media session but no associated routing
 *     session"), which a non-casting app never has, so the key adjusts a stream instead. On
 *     API 34 only, a one-step change of STREAM_MUSIC while no other app's music is active
 *     (otherwise the press was the user turning Spotify down) and not within
 *     [DEVICE_CHANGE_QUIET_MS] of an audio-device change (headset in/out, BT connect) is the
 *     press: lap, then put the stream back (own broadcast suppressed). When music is active the
 *     fallback is off and [onUnavailable] fires once so the UI can say "use the lock-screen LAP".
 *     Limits: a key at the end of the range changes nothing; a one-step programmatic change is
 *     indistinguishable from a key; `VOLUME_CHANGED_ACTION` extras are not public API.
 *
 * Known limit of both: with another player active the keys go to that session; the
 * notification LAP stays primary. 400 ms debounce here, again in the core.
 */
class LapInput(
    context: Context,
    private val onLap: () -> Unit,
    private val onUnavailable: (() -> Unit)? = null,
    private val streamFallback: Boolean = Build.VERSION.SDK_INT == Build.VERSION_CODES.UPSIDE_DOWN_CAKE,
) {
    private val context = context.applicationContext
    private val audio = this.context.getSystemService(Context.AUDIO_SERVICE) as AudioManager
    private var session: MediaSession? = null
    private var receiver: BroadcastReceiver? = null
    private var deviceCallback: AudioDeviceCallback? = null
    private var lastPressT = 0L
    private var unavailableReported = false

    /** Broadcasts caused by our own restore are ignored until this time. */
    private var suppressUntil = 0L

    /** Last audio-device change (elapsedRealtime); stream changes right after it are not presses. */
    private var deviceChangeT = Long.MIN_VALUE

    /** Which path landed the last lap: "session" or "stream" (tests and the CI trace). */
    var lastPath: String? = null
        private set

    private fun press(source: String): Boolean {
        val now = SystemClock.elapsedRealtime()
        if (now - lastPressT < DEBOUNCE_MS) return false
        lastPressT = now
        lastPath = source
        Log.i(TAG, "lap from $source")
        onLap()
        return true
    }

    private fun reportUnavailable(why: String) {
        if (unavailableReported) return
        unavailableReported = true
        Log.i(TAG, "volume-key laps unavailable: $why")
        onUnavailable?.invoke()
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
        if (streamFallback) enableStreamFallback()
        Log.i(TAG, "volume-key lap enabled (streamFallback=$streamFallback)")
    }

    private fun enableStreamFallback() {
        if (audio.isMusicActive) reportUnavailable("music active on Android 14")
        val cb = object : AudioDeviceCallback() {
            override fun onAudioDevicesAdded(added: Array<out AudioDeviceInfo>) { deviceChangeT = SystemClock.elapsedRealtime() }
            override fun onAudioDevicesRemoved(removed: Array<out AudioDeviceInfo>) { deviceChangeT = SystemClock.elapsedRealtime() }
        }
        audio.registerAudioDeviceCallback(cb, Handler(Looper.getMainLooper()))
        deviceCallback = cb
        val r = object : BroadcastReceiver() {
            override fun onReceive(c: Context, intent: Intent) {
                when (intent.action) {
                    AudioManager.ACTION_AUDIO_BECOMING_NOISY -> deviceChangeT = SystemClock.elapsedRealtime()
                    VOLUME_CHANGED_ACTION -> onVolumeChanged(intent)
                }
            }
        }
        val filter = IntentFilter().apply {
            addAction(VOLUME_CHANGED_ACTION)
            addAction(AudioManager.ACTION_AUDIO_BECOMING_NOISY)
        }
        ContextCompat.registerReceiver(context, r, filter, ContextCompat.RECEIVER_EXPORTED)
        receiver = r
    }

    private fun onVolumeChanged(intent: Intent) {
        val stream = intent.getIntExtra(EXTRA_STREAM_TYPE, -1)
        val value = intent.getIntExtra(EXTRA_STREAM_VALUE, -1)
        val prev = intent.getIntExtra(EXTRA_PREV_STREAM_VALUE, value)
        if (stream != AudioManager.STREAM_MUSIC || value < 0) return
        val now = SystemClock.elapsedRealtime()
        if (now < suppressUntil) return
        if (Math.abs(value - prev) != 1) {
            Log.i(TAG, "volume changed $prev→$value: not a single key step, ignored")
            return
        }
        if (now - deviceChangeT < DEVICE_CHANGE_QUIET_MS) {
            Log.i(TAG, "volume changed $prev→$value within ${DEVICE_CHANGE_QUIET_MS} ms of an audio-device change, ignored")
            return
        }
        if (audio.isMusicActive) {
            Log.i(TAG, "volume changed $prev→$value while music is active: the user's volume, not a lap")
            reportUnavailable("music active on Android 14")
            return
        }
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
        deviceCallback?.let { audio.unregisterAudioDeviceCallback(it) }
        deviceCallback = null
    }

    companion object {
        private const val TAG = "RunSolo/lapinput"
        private const val DEBOUNCE_MS = 400L
        private const val RESTORE_SUPPRESS_MS = 500L
        const val DEVICE_CHANGE_QUIET_MS = 2_000L

        // AudioManager's broadcast for any stream volume change (action string public, extras @hide).
        const val VOLUME_CHANGED_ACTION = "android.media.VOLUME_CHANGED_ACTION"
        const val EXTRA_STREAM_TYPE = "android.media.EXTRA_VOLUME_STREAM_TYPE"
        const val EXTRA_STREAM_VALUE = "android.media.EXTRA_VOLUME_STREAM_VALUE"
        const val EXTRA_PREV_STREAM_VALUE = "android.media.EXTRA_PREV_VOLUME_STREAM_VALUE"
    }
}
