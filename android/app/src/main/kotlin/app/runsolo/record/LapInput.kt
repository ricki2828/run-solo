package app.runsolo.record

import android.content.Context
import android.media.AudioManager
import android.media.VolumeProvider
import android.media.session.MediaSession
import android.media.session.PlaybackState
import android.os.SystemClock
import android.util.Log

/**
 * Volume-key LAP (plan §3, W8): opt-in, on by default only in Free mode. Volume keys reach
 * an app only through the active MediaSession's `VolumeProvider` (remote playback), which
 * takes the keys away from the music volume while it is active — so it is off by default in
 * preset mode and the notification/lock-screen LAP action stays primary.
 *
 * Known limit: a MediaSession only receives keys while it is the system's active playing
 * session. With Spotify (or any player) playing, the keys go there and the volume-key lap
 * does nothing; the notification LAP still works. 400 ms debounce here, again in the core.
 */
class LapInput(context: Context, private val onLap: () -> Unit) {
    private val context = context.applicationContext
    private var session: MediaSession? = null
    private var lastPressT = 0L

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
                val now = SystemClock.elapsedRealtime()
                if (now - lastPressT < 400) return
                lastPressT = now
                onLap()
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
    }
}
