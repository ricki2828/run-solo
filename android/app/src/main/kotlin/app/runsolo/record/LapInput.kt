package app.runsolo.record

import android.content.Context
import android.media.AudioManager
import android.media.VolumeProvider
import android.media.session.MediaSession
import android.media.session.PlaybackState
import android.os.Build
import android.os.SystemClock
import android.util.Log

/**
 * Volume-key LAP (plan §3, W8): opt-in, on by default only in Laps mode (never in Free, which
 * takes no laps at all). An active MediaSession with a remote [VolumeProvider]: while it is the
 * system's volume target the keys come here and never touch the music volume (API 29 and 36
 * verified on the CI emulators).
 *
 * Android 14 (API 34) is off: it routes volume keys to a remote session only when the app owns
 * a MediaRouter2 routing session ("has a remote media session but no associated routing
 * session"), which a non-casting app never has. A STREAM_MUSIC change-broadcast fallback was
 * tried and dropped (PR #9): with nothing playing and the volume panel hidden, AudioService
 * swallows a lone key press (it only shows the panel), so a single press, and every screen-off
 * press, changes nothing and cannot be seen. On 34 no session is registered and [onUnavailable]
 * fires once so the UI can say "use the lock-screen LAP".
 *
 * Known limit: with another player active the keys go to that session; the notification LAP
 * stays primary. 400 ms debounce here, again in the core.
 */
class LapInput(
    context: Context,
    private val onLap: () -> Unit,
    private val onUnavailable: (() -> Unit)? = null,
    private val keysReachSession: Boolean = SUPPORTED,
) {
    private val context = context.applicationContext
    private var session: MediaSession? = null
    private var lastPressT = -DEBOUNCE_MS // a press at elapsedRealtime < 400 ms (Robolectric's clock starts near 0) is not debounced
    private var unavailableReported = false

    /** Whether the volume-key MediaSession is registered (tests). */
    val registered: Boolean
        get() = session != null

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
        if (!keysReachSession) {
            if (!unavailableReported) {
                unavailableReported = true
                Log.i(TAG, "volume-key laps unavailable on API ${Build.VERSION.SDK_INT}: keys never reach an app session")
                onUnavailable?.invoke()
            }
            return
        }
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
        Log.i(TAG, "volume-key lap enabled")
    }

    fun disable() {
        session?.let {
            it.isActive = false
            it.release()
        }
        session = null
    }

    companion object {
        private const val TAG = "RunSolo/lapinput"
        private const val DEBOUNCE_MS = 400L

        /** Volume keys reach an app's session everywhere but Android 14 (see the class doc). */
        val SUPPORTED: Boolean
            get() = Build.VERSION.SDK_INT != Build.VERSION_CODES.UPSIDE_DOWN_CAKE
    }
}
