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
import app.runsolo.core.live.CueSlot
import app.runsolo.core.live.LiveCoach
import app.runsolo.core.live.NudgeFollowUp
import app.runsolo.core.live.SpeechClock
import app.runsolo.core.live.TalkBudget
import app.runsolo.core.live.TalkLine
import app.runsolo.core.live.VoiceLevel
import app.runsolo.core.model.CueKind
import java.util.Locale

/**
 * Speaks the session cues (plan §3): TextToSpeech bound to the application context (it must
 * outlive the Activity — swiping the task away mid-run keeps the service alive), audio focus
 * `TRANSIENT_MAY_DUCK` held only for the utterance (music ducks for the cue, then recovers), a
 * tone fallback when TTS is missing or `speak` fails, and a short vibration on every cue so a
 * pocketed phone still registers. [enabled] mirrors `setCues`.
 */
/**
 * [now]: the session's clock for the 3 s stale rule; a replay passes its trace clock, so what is
 * dropped depends on trace time only, as in the JVM transcript fixture (T4).
 */
class CuePlayer(context: Context, private val now: () -> Long = { SystemClock.elapsedRealtime() }) {
    private val context = context.applicationContext
    private val audio = this.context.getSystemService(Context.AUDIO_SERVICE) as AudioManager
    private val main = Handler(Looper.getMainLooper())
    private var tts: TextToSpeech? = null
    private var ttsReady = false
    private var tone: ToneGenerator? = null
    private var focus: AudioFocusRequest? = null

    private val speech = SpeechClock()
    private val followUp = NudgeFollowUp()

    /** The one arbiter of what is said (cadence v1): every spoken line below is offered to it first. */
    private val budget = TalkBudget()

    /** Settings → Voice → "Voice detail" for this run; set before start, read on the recorder thread. */
    var voiceLevel: VoiceLevel
        get() = synchronized(this) { budget.level }
        set(v) = synchronized(this) { budget.level = v }

    private var seq = 0

    /** The last [play] was dropped by the budget (not by cues being off): its compare was never said, so it is not journaled as fired. */
    private var dropped = false

    /** True once when the last [play] was dropped by the [TalkBudget]. */
    @Synchronized
    fun consumeDropped(): Boolean = dropped.also { dropped = false }

    /** Steep and zone 4+ right now: the km and half km lines stay quiet (set by the session each tick). */
    @Volatile
    var hardEffort: Boolean = false

    /** Utterances/tones in flight; focus is abandoned when it returns to zero. */
    private var inFlight = 0
    var enabled: Boolean = true

    /** A summary line asked for before TTS finished starting; said once it is ready (or toned if it never is). */
    private var pendingLine: String? = null
    private var releaseWhenIdle = false

    /** When the start briefing is estimated to end (session clock); 0 = none in flight. A step boundary before it flushes it. */
    private var briefingEndsAt = 0L
    private var pendingQuiet: String? = null

    fun init() {
        try {
            tts = TextToSpeech(context) { status ->
                ttsReady = status == TextToSpeech.SUCCESS
                main.post { flushPending() }
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
        pendingLine = null
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
     * A cue with a live compare ([extra], Phase 4 §3.2) appended, within the 16-word budget; the
     * compare is dropped when the speech queued ahead would make it start more than 3 s late
     * ([SpeechClock]), the base cue is still said. [kind] null = a Free run's km split, with a
     * short vibration. A [nudge] (§3.5) is not appended: it follows as its own line once this cue
     * is done ([NudgeFollowUp], [dueNudge]). Any cue, countdown tones included, drops a follow-up
     * still waiting. Returns what was composed (null when nothing was said).
     *
     * A [tail] (the km check-in's extra metrics) is said in the same utterance after the compare, so
     * nothing can slip between them and it queues once. It sits outside the 16-word budget (the
     * check-in caps itself) and is dropped, like a compare, when the speech queued ahead would make
     * it start more than 3 s late; the base km line is still said then.
     */
    @Synchronized
    fun play(
        kind: CueKind?,
        text: String?,
        extra: String?,
        nudge: LiveCoach.Nudge? = null,
        tail: String? = null,
        slot: CueSlot = if (kind == null) CueSlot.km else CueSlot.structure,
        key: String? = null,
    ): CueComposer.Composed? {
        if (!enabled) {
            vibrate(kind ?: CueKind.minuteMark)
            return null
        }
        followUp.cancel()
        if (kind == CueKind.countdown) {
            vibrate(kind)
            countdown()
            return null
        }
        val t = now()
        val fresh = speech.freshAt(t)
        val composed = CueComposer.compose(text, extra?.takeIf { fresh })
        val head = composed.text
        if (head == null) {
            vibrate(kind ?: CueKind.minuteMark)
            return null
        }
        val full = if (tail != null && fresh) "${head.trimEnd()} $tail" else head
        // Interval and plan cues (a kind) are structure: they always speak. A km or half km line can be dropped or merged.
        val line = TalkLine(slot, key ?: "${slot.name}:${seq++}", full, whole = composed.compareSpoken)
        val offered = budget.offer(line, t, speech.busyUntil, hardEffort)
        if (offered == null) {
            dropped = true
            return null
        }
        // A step boundary (go, rep end) inside the start briefing cuts it off, so the cue is on time.
        if ((kind == CueKind.start || kind == CueKind.phaseEnd) && SpeechClock.interrupts(briefingEndsAt, t)) {
            briefingEndsAt = 0L
            flushSpeech(t)
        }
        vibrate(kind ?: CueKind.minuteMark)
        val words = offered.text
        speech.queued(t, CueComposer.words(words))
        say(kind, words)
        nudge?.let { followUp.offer(it, speech.busyUntil) }
        return if (words === head) composed else composed.copy(text = words)
    }

    /** A trail moment (climb ahead, ghost flip, final push, finish...): offered to the budget, said only when it passes. Null = dropped or held. */
    @Synchronized
    fun moment(line: TalkLine): TalkLine? {
        if (!enabled) return null
        val t = now()
        val out = budget.offer(line, t, speech.busyUntil, hardEffort) ?: return null
        sayMoment(out, t)
        return out
    }

    /** Once a tick: a held game beat whose gap has opened, said here; null when none is. The caller journals it. */
    @Synchronized
    fun dueMoment(): TalkLine? {
        if (!enabled) return null
        val t = now()
        val out = budget.poll(t, speech.busyUntil) ?: return null
        sayMoment(out, t)
        return out
    }

    private fun sayMoment(line: TalkLine, t: Long) {
        followUp.cancel()
        vibrate(CueKind.minuteMark)
        speech.queued(t, line.words)
        say(null, line.text)
    }

    /** When the speech queued so far will be done, on the session's clock (voice coaching only speaks when this has passed). */
    val speechBusyUntil: Long get() = synchronized(this) { speech.busyUntil }

    /**
     * Like [speechBusyUntil], and on the Coach level not before the budget's gap has opened: voice coaching keeps its own
     * cooldown, so it must not fire a line the budget would then drop.
     */
    val coachBusyUntil: Long
        get() = synchronized(this) {
            val busy = speech.busyUntil
            if (budget.level == VoiceLevel.coach) maxOf(busy, budget.gapOpensAt(now(), busy)) else busy
        }

    /** A nudge is waiting to follow its cue; coaching holds off so it is not dropped. */
    val nudgePending: Boolean get() = synchronized(this) { followUp.pending != null }

    /** A pause or Mute tips: a follow-up nudge still waiting is not said. */
    @Synchronized
    fun dropNudge() = followUp.cancel()

    /** Once a tick: the follow-up nudge now due, said here; null when none is (or it was dropped). The caller journals it. */
    @Synchronized
    fun dueNudge(): LiveCoach.Nudge? {
        val t = now()
        val n = followUp.due(t, speech.busyUntil) ?: return null
        if (!enabled) return null
        // A nudge is the tail of its km cue: it is counted against the budget but never gated by it.
        budget.record(TalkLine(CueSlot.paceStatus, "nudge:${n.rule}:${n.index}", n.text), t, speech.busyUntil)
        speech.queued(t, CueComposer.words(n.text))
        say(null, n.text)
        return n
    }

    /** The goal-reached line (§G): a long double buzz, then the words (spoken even over a queue: it is the moment). */
    @Synchronized
    fun goal(text: String) {
        vibrate(longArrayOf(0, 400, 150, 400))
        if (!enabled) return
        followUp.cancel()
        budget.record(TalkLine(CueSlot.finish, "goal:${seq++}", text), now(), speech.busyUntil)
        speech.queued(now(), CueComposer.words(text))
        say(CueKind.phaseEnd, text)
    }

    /**
     * A route alert (off route, back on route, a turn ahead): the buzz always (a pocketed phone, music playing), the
     * words only when cues are on. Never drops or delays a cue already queued: it is said in order like any line.
     */
    @Synchronized
    fun alert(text: String, pattern: LongArray, slot: CueSlot = CueSlot.turnaround) {
        vibrate(pattern)
        announce(text, slot)
    }

    /**
     * A spoken summary (start or end of a run, [SummaryWords][app.runsolo.core.record.SummaryWords]): no
     * vibration, and unlike [announce] it waits for TTS to finish starting instead of falling back to a
     * tone, because it is asked for right after [init]. [then] true releases the player once the line
     * is done (the end-of-run player has nothing else to say).
     */
    @Synchronized
    fun announceSummary(text: String, thenRelease: Boolean = false, briefing: Boolean = false) {
        if (!enabled) {
            if (thenRelease) release()
            return
        }
        releaseWhenIdle = thenRelease
        followUp.cancel()
        budget.record(TalkLine(CueSlot.structure, "summary:${seq++}", text), now(), speech.busyUntil)
        speech.queued(now(), CueComposer.words(text))
        if (briefing) briefingEndsAt = speech.busyUntil
        if (ttsReady || tts == null) say(null, text) else pendingLine = text
        if (thenRelease) main.postDelayed({ release() }, RELEASE_SAFETY_MS)
    }

    /** Releases now when nothing is being said, else once the last line is done, and in any case within [IDLE_CAP_MS]. */
    @Synchronized
    fun releaseWhenIdle() {
        if (inFlight == 0 && pendingLine == null) return release()
        releaseWhenIdle = true
        main.postDelayed({ release() }, IDLE_CAP_MS)
    }

    @Synchronized
    private fun flushPending() {
        pendingQuiet?.let {
            pendingQuiet = null
            if (ttsReady) speakIfReady(it)
        }
        val line = pendingLine ?: return
        pendingLine = null
        say(null, line)
    }

    /**
     * Spoken without a vibration pattern of its own (e.g. "GPS weak"). [slot] says how much it matters: the default,
     * structure, always speaks; a coaching line (zone drift, pace status) can be dropped by the [TalkBudget].
     */
    @Synchronized
    fun announce(text: String, slot: CueSlot = CueSlot.structure) {
        if (!enabled) return
        val t = now()
        budget.offer(TalkLine(slot, "${slot.name}:${seq++}", text), t, speech.busyUntil, hardEffort) ?: return
        followUp.cancel()
        speech.queued(t, CueComposer.words(text))
        say(null, text)
    }

    /**
     * One short line for a screen with no recording (the Ready countdown): spoken only when TTS is
     * ready, interrupting any earlier beat, with no tone fallback and no vibration. Returns whether
     * it was handed to the engine; false means it was dropped and nothing sounded.
     */
    @Synchronized
    fun speakIfReady(text: String): Boolean {
        val engine = tts
        if (enabled && !ttsReady && engine != null) {
            // TTS is still starting: keep the line for up to 300 ms, then it is stale.
            pendingQuiet = text
            main.postDelayed({ synchronized(this) { if (pendingQuiet == text) pendingQuiet = null } }, QUIET_WAIT_MS)
            return false
        }
        if (!enabled || !ttsReady || engine == null) return false
        requestFocus()
        inFlight++
        val spoke = try {
            engine.speak(text, TextToSpeech.QUEUE_FLUSH, null, "cue-${System.nanoTime()}") == TextToSpeech.SUCCESS
        } catch (_: Exception) {
            false
        }
        if (!spoke) done()
        return spoke
    }

    /** Stops what is being said and forgets what was queued behind it; the next line starts now. */
    private fun flushSpeech(t: Long) {
        try {
            tts?.stop()
        } catch (_: Exception) {
        }
        speech.interrupt(t)
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
        // The Ready countdown's "Go" is still being said by its own engine: wait it out.
        val wait = holdSpeechUntil - SystemClock.elapsedRealtime()
        if (wait > 0) main.postDelayed({ sayNow(kind, text) }, wait) else sayNow(kind, text)
    }

    @Synchronized
    private fun sayNow(kind: CueKind?, text: String) {
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
        if (inFlight == 0) {
            abandonFocus()
            if (releaseWhenIdle && pendingLine == null) release()
        }
    }

    private fun vibrate(kind: CueKind) = vibrate(
        when (kind) {
            CueKind.start, CueKind.phaseEnd -> longArrayOf(0, 120, 80, 120)
            CueKind.stop -> longArrayOf(0, 300)
            else -> longArrayOf(0, 80)
        },
    )

    private fun vibrate(pattern: LongArray) {
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

        /** How long a Ready countdown beat waits for TTS to finish starting. */
        private const val QUIET_WAIT_MS = 300L

        /** How long a run's own speech waits after the countdown's "Go" (its engine is separate; completion is not observable here). */
        const val GO_HOLD_MS = 1_200L

        /** [SystemClock.elapsedRealtime] before which a run's cues are held back; 0 = no hold. */
        @Volatile
        var holdSpeechUntil = 0L

        /** A one-shot player is released this long after its line was asked for, whatever TTS did. */
        /** The longest a finished run's last cue may keep the player alive. */
        private const val IDLE_CAP_MS = 2_000L

        private const val RELEASE_SAFETY_MS = 30_000L
    }
}
