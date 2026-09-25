package app.runsolo.record

import android.content.Context
import android.media.AudioAttributes
import android.media.AudioFocusRequest
import android.media.AudioManager
import android.media.ToneGenerator
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.VibrationEffect
import android.os.Vibrator
import android.os.VibratorManager
import android.speech.tts.TextToSpeech
import android.speech.tts.UtteranceProgressListener
import android.util.Log
import app.runsolo.core.model.CueKind
import app.runsolo.core.model.Phase
import java.util.Locale

/**
 * Speaks the session cues (plan §3): TextToSpeech bound to the application context (it must
 * outlive the Activity — swiping the task away mid-run keeps the service alive), audio focus
 * `TRANSIENT_MAY_DUCK` held only for the utterance (music ducks for the cue, then recovers), a
 * tone fallback when TTS is missing or `speak` fails, and a short vibration on every cue so a
 * pocketed phone still registers. [enabled] mirrors `setCues`.
 */
class CuePlayer(context: Context) {
    private val context = context.applicationContext
    private val audio = this.context.getSystemService(Context.AUDIO_SERVICE) as AudioManager
    private val main = Handler(Looper.getMainLooper())
    private var tts: TextToSpeech? = null
    private var ttsReady = false
    private var tone: ToneGenerator? = null
    private var focus: AudioFocusRequest? = null

    /** Utterances/tones in flight; focus is abandoned when it returns to zero. */
    private var inFlight = 0
    var enabled: Boolean = true

    fun init() {
        try {
            tts = TextToSpeech(context) { status ->
                ttsReady = status == TextToSpeech.SUCCESS
                if (ttsReady) {
                    tts?.setLanguage(Locale.getDefault())
                    tts?.setOnUtteranceProgressListener(object : UtteranceProgressListener() {
                        override fun onStart(utteranceId: String?) = Unit
                        override fun onDone(utteranceId: String?) {
                            main.post { done() }
                        }

                        @Deprecated("Deprecated in Java")
                        override fun onError(utteranceId: String?) {
                            main.post { done() }
                        }

                        override fun onError(utteranceId: String?, errorCode: Int) {
                            main.post { done() }
                        }

                        override fun onStop(utteranceId: String?, interrupted: Boolean) {
                            main.post { done() }
                        }
                    })
                }
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

    @Synchronized
    fun release() {
        try {
            tts?.stop()
            tts?.shutdown()
        } catch (_: Exception) {
        }
        tts = null
        tone?.release()
        tone = null
        inFlight = 0
        abandonFocus()
    }

    /** [nextPhase] is the phase that starts at a `phaseEnd`/`start` cue, for the wording. Called from the recorder thread; [done] from main. */
    @Synchronized
    fun play(kind: CueKind, nextPhase: Phase, repIndex: Int) {
        vibrate(kind)
        if (!enabled) return
        val text = when (kind) {
            CueKind.start -> if (nextPhase == Phase.work) "Go. Rep $repIndex" else "Recover"
            CueKind.halfway -> "Halfway"
            CueKind.thirtySeconds -> "Thirty seconds"
            CueKind.phaseEnd -> if (nextPhase == Phase.cooldown) "Done. Cool down" else null // the next `start` cue says what comes
            CueKind.stop -> "Run saved"
            // Phase 3 cues (I2): the core never emits them yet; no wording until it does.
            CueKind.distanceToGo, CueKind.lastRep, CueKind.minuteMark, CueKind.countdown, CueKind.projection -> null
        } ?: return
        requestFocus()
        inFlight++
        val engine = tts
        val spoke = ttsReady && engine != null &&
            engine.speak(text, TextToSpeech.QUEUE_ADD, null, "cue-${System.nanoTime()}") == TextToSpeech.SUCCESS
        if (!spoke) {
            val toneType = if (kind == CueKind.start) ToneGenerator.TONE_PROP_BEEP2 else ToneGenerator.TONE_PROP_BEEP
            tone?.startTone(toneType, 250)
            main.postDelayed({ done() }, 300)
        }
    }

    @Synchronized
    private fun done() {
        if (inFlight > 0) inFlight--
        if (inFlight == 0) abandonFocus()
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
