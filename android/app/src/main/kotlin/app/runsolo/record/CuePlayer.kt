package app.runsolo.record

import android.content.Context
import android.media.AudioAttributes
import android.media.AudioFocusRequest
import android.media.AudioManager
import android.media.ToneGenerator
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.os.VibrationEffect
import android.os.Vibrator
import android.os.VibratorManager
import android.speech.tts.TextToSpeech
import android.speech.tts.UtteranceProgressListener
import android.util.Log
import app.runsolo.core.live.CueComposer
import app.runsolo.core.live.SpeechClock
import app.runsolo.core.model.CueKind
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

    private val speech = SpeechClock()

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

    /**
     * One cue: a vibration, then [text] (from `CueWords`, JVM-tested) or, for `countdown`, three
     * tones a second apart. Called from the recorder thread; [done] from main.
     */
    @Synchronized
    fun play(kind: CueKind, text: String?) {
        play(kind, text, null)
    }

    /**
     * A cue with a live compare ([extra], Phase 4 §3.2) and a nudge ([nudge], §3.5) appended:
     * composed within the 16-word budget (base > compare > nudge), both extras dropped when the
     * speech queued ahead would make them start more than 3 s late ([SpeechClock]); the base cue
     * is still said. [kind] null = a Free run's km split, with a short vibration. Returns what was
     * composed (null when nothing was said), so a nudge is journaled only when spoken.
     */
    @Synchronized
    fun play(kind: CueKind?, text: String?, extra: String?, nudge: String? = null): CueComposer.Composed? {
        vibrate(kind ?: CueKind.minuteMark)
        if (!enabled) return null
        if (kind == CueKind.countdown) {
            countdown()
            return null
        }
        val now = SystemClock.elapsedRealtime()
        val fresh = speech.freshAt(now)
        val composed = CueComposer.compose(text, extra?.takeIf { fresh }, nudge?.takeIf { fresh })
        val words = composed.text ?: return null
        speech.queued(now, CueComposer.words(words))
        say(kind, words)
        return composed
    }

    /** Spoken without a vibration pattern of its own (e.g. "GPS weak"). */
    @Synchronized
    fun announce(text: String) {
        if (!enabled) return
        speech.queued(SystemClock.elapsedRealtime(), CueComposer.words(text))
        say(null, text)
    }

    private fun countdown() {
        requestFocus()
        for (i in 0..2) {
            inFlight++
            main.postDelayed({
                synchronized(this) { tone?.startTone(if (i == 2) ToneGenerator.TONE_PROP_BEEP2 else ToneGenerator.TONE_PROP_BEEP, 200) }
                main.postDelayed({ done() }, 250)
            }, i * 1_000L)
        }
    }

    private fun say(kind: CueKind?, text: String) {
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
