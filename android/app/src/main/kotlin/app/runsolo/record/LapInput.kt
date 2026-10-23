package app.runsolo.record

import android.content.Context
import android.media.AudioManager
import android.media.VolumeProvider
import android.media.session.MediaSession
import android.media.session.PlaybackState
import android.content.Intent
import android.view.KeyEvent
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
    /**
     * A press while a coach prompt is open ([holdForPrompt]) goes here instead of taking a lap: one press = the first
     * answer, two quick presses = the second (the session counts them). Never called outside a prompt window, so a
     * press then is exactly the lap press it always was.
     */
    private val onPromptPress: (() -> Unit)? = null,
) {
    private val context = context.applicationContext
    private var session: MediaSession? = null
    private var lastPressT = -DEBOUNCE_MS // a press at elapsedRealtime < 400 ms (Robolectric's clock starts near 0) is not debounced
    private var unavailableReported = false

    /** A coach prompt is open: presses answer it. Written on the recorder thread, read on the main thread. */
    @Volatile
    private var promptOpen = false

    /** The session exists only for the prompt window (no volume-key laps in this mode): released when it closes. */
    private var promptOnly = false

    /** Whether the volume-key MediaSession is registered (tests). */
    val registered: Boolean
        get() = session != null

    private fun press(source: String): Boolean {
        if (promptOpen) {
            val answer = onPromptPress
            if (answer != null) {
                Log.i(TAG, "prompt press from $source")
                answer()
                return true
            }
        }
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
        session = buildSession(volumeKeys = true)
        Log.i(TAG, "volume-key lap enabled")
    }

    /**
     * A coach prompt opened ([open] true) or closed. While it is open the headset buttons (play/pause, the hook) and,
     * where they reach an app session, the volume keys answer it. With no volume-key lap session in this mode a
     * session is made for the window only and released after, so music apps get their buttons back at once.
     */
    fun holdForPrompt(open: Boolean) {
        promptOpen = open
        if (open) {
            if (session == null) {
                session = buildSession(volumeKeys = keysReachSession)
                promptOnly = true
            }
        } else if (promptOnly) {
            promptOnly = false
            disable()
        }
    }

    private fun buildSession(volumeKeys: Boolean): MediaSession {
        val s = MediaSession(context, "RunSolo lap")
        s.setCallback(object : MediaSession.Callback() {
            @Suppress("DEPRECATION")
            override fun onMediaButtonEvent(mediaButtonIntent: Intent): Boolean {
                if (!promptOpen) return false
                val e = mediaButtonIntent.getParcelableExtra<KeyEvent>(Intent.EXTRA_KEY_EVENT) ?: return false
                if (e.action != KeyEvent.ACTION_DOWN || e.repeatCount != 0) return false
                return when (e.keyCode) {
                    KeyEvent.KEYCODE_HEADSETHOOK, KeyEvent.KEYCODE_MEDIA_PLAY_PAUSE, KeyEvent.KEYCODE_MEDIA_PLAY, KeyEvent.KEYCODE_MEDIA_PAUSE -> press("headset")
                    else -> false
                }
            }
        })
        s.setPlaybackState(
            PlaybackState.Builder()
                .setActions(PlaybackState.ACTION_PLAY or PlaybackState.ACTION_PAUSE)
                .setState(PlaybackState.STATE_PLAYING, 0, 1f, SystemClock.elapsedRealtime())
                .build(),
        )
        if (volumeKeys) {
            s.setPlaybackToRemote(object : VolumeProvider(VolumeProvider.VOLUME_CONTROL_RELATIVE, 50, 50) {
                override fun onAdjustVolume(direction: Int) {
                    Log.i(TAG, "volume key direction=$direction")
                    if (direction == AudioManager.ADJUST_SAME) return
                    press("session")
                }
            })
        }
        s.isActive = true
        return s
    }

    fun disable() {
        promptOnly = false
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
