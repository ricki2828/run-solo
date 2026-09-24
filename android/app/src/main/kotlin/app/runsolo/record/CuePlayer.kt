package app.runsolo.record

import android.content.Context
import android.media.AudioAttributes
import android.media.AudioFocusRequest
import android.media.AudioManager
import android.media.ToneGenerator
import android.os.Build
import android.os.VibrationEffect
import android.os.Vibrator
import android.os.VibratorManager
import android.speech.tts.TextToSpeech
import android.util.Log
import app.runsolo.core.model.CueKind
import app.runsolo.core.model.Phase
import java.util.Locale

/**
 * Speaks the preset cues (plan §3): TextToSpeech with audio focus TRANSIENT_MAY_DUCK, a tone
 * fallback when TTS is unavailable, and a short vibration on every cue so a pocketed phone
 * still registers. [enabled] mirrors `setCues`.
 */
class CuePlayer(private val context: Context) {
    private val audio = context.getSystemService(Context.AUDIO_SERVICE) as AudioManager
    private var tts: TextToSpeech? = null
    private var ttsReady = false
    private var tone: ToneGenerator? = null
    private var focus: AudioFocusRequest? = null
    var enabled: Boolean = true

    fun init() {
        try {
            tts = TextToSpeech(context) { status ->
                ttsReady = status == TextToSpeech.SUCCESS
                if (ttsReady) tts?.setLanguage(Locale.getDefault())
                Log.i(TAG, "tts ready=$ttsReady")
            }
        } catch (e: Exception) {
            Log.w(TAG, "tts init failed: $e")
        }
        tone = try {
            ToneGenerator(AudioManager.STREAM_MUSIC, 80)
        } catch (_: Exception) {
            null
        }
    }

    fun release() {
        tts?.shutdown()
        tts = null
        tone?.release()
        tone = null
        abandonFocus()
    }

    /** [nextPhase] is the phase that starts at a `phaseEnd`/`start` cue, for the wording. */
    fun play(kind: CueKind, nextPhase: Phase, repIndex: Int) {
        vibrate(kind)
        if (!enabled) return
        val text = when (kind) {
            CueKind.start -> if (nextPhase == Phase.work) "Go. Rep $repIndex" else "Recover"
            CueKind.halfway -> "Halfway"
            CueKind.thirtySeconds -> "Thirty seconds"
            CueKind.phaseEnd -> if (nextPhase == Phase.cooldown) "Done. Cool down" else null // the next `start` cue says what comes
            CueKind.stop -> "Run saved"
        } ?: return
        requestFocus()
        val engine = tts
        if (ttsReady && engine != null) {
            engine.speak(text, TextToSpeech.QUEUE_ADD, null, "cue-${System.nanoTime()}")
        } else {
            val toneType = if (kind == CueKind.start) ToneGenerator.TONE_PROP_BEEP2 else ToneGenerator.TONE_PROP_BEEP
            tone?.startTone(toneType, 250)
        }
    }

    private fun vibrate(kind: CueKind) {
        val pattern = when (kind) {
            CueKind.start, CueKind.phaseEnd -> longArrayOf(0, 120, 80, 120)
            CueKind.stop -> longArrayOf(0, 300)
            else -> longArrayOf(0, 80)
        }
        try {
            val v = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                (context.getSystemService(Context.VIBRATOR_MANAGER_SERVICE) as VibratorManager).defaultVibrator
            } else {
                @Suppress("DEPRECATION")
                context.getSystemService(Context.VIBRATOR_SERVICE) as Vibrator
            }
            v.vibrate(VibrationEffect.createWaveform(pattern, -1))
        } catch (_: Exception) {
        }
    }

    private fun requestFocus() {
        if (focus != null) return
        val req = AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN_TRANSIENT_MAY_DUCK)
            .setAudioAttributes(
                AudioAttributes.Builder()
                    .setUsage(AudioAttributes.USAGE_ASSISTANCE_NAVIGATION_GUIDANCE)
                    .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
                    .build(),
            )
            .setWillPauseWhenDucked(false)
            .build()
        focus = req
        audio.requestAudioFocus(req)
    }

    private fun abandonFocus() {
        focus?.let { audio.abandonAudioFocusRequest(it) }
        focus = null
    }

    companion object {
        private const val TAG = "RunSolo/cues"
    }
}
