package app.runsolo.core.live

/**
 * When queued speech will be done (WARN-2's 3 s rule): TextToSpeech queues utterances, so a cue
 * that arrives while earlier ones are still speaking starts late. A compare or nudge that could
 * not start within [STALE_MS] of its trigger is dropped (it would describe a moment that has
 * passed); the base cue itself is still spoken. Durations are an estimate from the word count
 * at the TTS rate ([MS_PER_WORD]: 16 words in about 6 s).
 */
class SpeechClock {
    /** When the speech queued so far will be done (an estimate). */
    var busyUntil = 0L
        private set

    /** True when an utterance queued at [nowMs] would start within [STALE_MS]. */
    fun freshAt(nowMs: Long): Boolean = busyUntil - nowMs <= STALE_MS

    /** [words] were queued at [nowMs]. */
    fun queued(nowMs: Long, words: Int) {
        busyUntil = maxOf(busyUntil, nowMs) + words * MS_PER_WORD
    }

    companion object {
        const val STALE_MS = 3_000L
        const val MS_PER_WORD = 375L
    }
}
