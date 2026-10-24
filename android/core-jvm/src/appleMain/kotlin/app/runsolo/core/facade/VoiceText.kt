package app.runsolo.core.facade

import app.runsolo.core.json.Json
import app.runsolo.core.live.LiveWords
import app.runsolo.core.model.CueKind
import app.runsolo.core.model.Phase
import app.runsolo.core.model.SessionSpec
import app.runsolo.core.record.CueWords

/**
 * The spoken words for the Swift `CuePlayer` (iOS plan P4), with primitives only so the ObjC header
 * stays plain: the same `CueWords` / `LiveWords` lines Android says. NaN or a negative number
 * stands for Kotlin null. RunnerTests compare these with the voice-copy fixture.
 */
object VoiceText {
    /** `CueWords.text`; [specJson] is the core's `SessionSpec.toJson()` shape. */
    @Throws(Exception::class)
    fun cue(kind: String, value: Double, specJson: String?, phase: String, repIndex: Int, stepIndex: Int, index: Int): String? {
        @Suppress("UNCHECKED_CAST")
        val spec = specJson?.let { SessionSpec.fromJson(Json.parse(it) as? Map<String, Any?>) }
        return CueWords.text(
            CueKind.valueOf(kind), value.takeUnless { it.isNaN() }, spec, Phase.valueOf(phase), repIndex,
            stepIndex.takeIf { it >= 0 }, index.takeIf { it >= 0 },
        )
    }

    /** A Free run's km split ("3 k, 15 minutes 20, pace 5:07."); a negative [splitMs] = pace unknown. */
    fun kmSplit(km: Int, activeMs: Long, splitMs: Long): String = LiveWords.kmSplit(km, activeMs, splitMs.takeIf { it >= 0 })

    /** The Ready screen's beat: 3, 2, 1, then 0 = "Go"; null for any other number. */
    fun countdownBeat(beat: Int): String? = CueWords.countdownBeat(beat)
}
