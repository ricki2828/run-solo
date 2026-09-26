package app.runsolo.platform

import app.runsolo.core.model.CueKind as CoreCue
import app.runsolo.core.model.LapSource as CoreLapSource
import app.runsolo.core.model.LiveBoard as CoreLiveBoard
import app.runsolo.core.model.LiveBoardKind as CoreLiveBoardKind
import app.runsolo.core.model.LiveContext as CoreLiveContext
import app.runsolo.core.model.LiveEntry as CoreLiveEntry
import app.runsolo.core.model.LiveTarget as CoreLiveTarget
import app.runsolo.core.model.NudgePlan as CoreNudgePlan
import app.runsolo.core.model.FastStartRule as CoreFastStart
import app.runsolo.core.model.HrDriftRule as CoreHrDrift
import app.runsolo.core.model.RepFadeRule as CoreRepFade
import app.runsolo.core.model.Phase as CorePhase
import app.runsolo.core.model.CueProfile as CoreCueProfile
import app.runsolo.core.model.RecoveryStyle as CoreRecoveryStyle
import app.runsolo.core.model.SessionSpec as CoreSpec
import app.runsolo.core.model.Step as CoreStep
import app.runsolo.core.model.StepKind as CoreStepKind
import app.runsolo.core.model.TargetKind as CoreTargetKind
import app.runsolo.core.model.RecorderState as CoreState
import app.runsolo.core.model.RunMode as CoreMode
import app.runsolo.core.model.Units as CoreUnits

/**
 * core-jvm enums are camelCase (they mirror the Dart names); Pigeon's Kotlin enums are
 * UPPER_SNAKE of the same names. Convert by name so the two cannot drift silently — a
 * missing value throws at the call site instead of mapping to the wrong thing.
 */
private fun String.toUpperSnake(): String = buildString {
    for (c in this@toUpperSnake) {
        if (c.isUpperCase()) append('_')
        append(c.uppercaseChar())
    }
}

private fun String.toCamel(): String = buildString {
    var up = false
    for (c in this@toCamel) {
        if (c == '_') { up = true; continue }
        append(if (up) c.uppercaseChar() else c.lowercaseChar())
        up = false
    }
}

fun CoreMode.toPigeon(): RecordMode = RecordMode.valueOf(name.toUpperSnake())
fun RecordMode.toCore(): CoreMode = CoreMode.valueOf(name.toCamel())
fun CoreUnits.toPigeon(): Units = Units.valueOf(name.toUpperSnake())
fun Units.toCore(): CoreUnits = CoreUnits.valueOf(name.toCamel())
fun CoreState.toPigeon(): RecorderState = RecorderState.valueOf(name.toUpperSnake())
fun CorePhase.toPigeon(): Phase = Phase.valueOf(name.toUpperSnake())
fun CoreLapSource.toPigeon(): LapSource = LapSource.valueOf(name.toUpperSnake())
fun LapSource.toCore(): CoreLapSource = CoreLapSource.valueOf(name.toCamel())
fun CoreCue.toPigeon(): CueKind = CueKind.valueOf(name.toUpperSnake())
fun CoreStep.toPigeon(): SessionStep = SessionStep(
    kind = StepKind.valueOf(kind.name.toUpperSnake()),
    target = TargetKind.valueOf(target.name.toUpperSnake()),
    value = value.toLong(),
    style = RecoveryStyle.valueOf(style.name.toUpperSnake()),
    repIndex = rep.toLong(),
)

fun SessionStep.toCore(): CoreStep = CoreStep(
    kind = CoreStepKind.valueOf(kind.name.toCamel()),
    target = CoreTargetKind.valueOf(target.name.toCamel()),
    value = value.toInt(),
    style = CoreRecoveryStyle.valueOf(style.name.toCamel()),
    rep = repIndex.toInt(),
)

fun CoreSpec.toPigeon(): SessionSpec = SessionSpec(
    templateId = templateId,
    templateVersion = templateVersion.toLong(),
    name = name,
    warmupSeconds = warmupSeconds?.toLong(),
    cooldownSeconds = cooldownSeconds?.toLong(),
    lapLockout = lapLockout,
    autoStop = autoStop,
    cueProfile = CueProfile.valueOf(cueProfile.name.toUpperSnake()),
    hrBandLow = hrBand?.first,
    hrBandHigh = hrBand?.second,
    steps = steps.map { it.toPigeon() },
)

/** Throws [IllegalArgumentException] for a half-given HR band; the caller reports `unsupportedSession`. */
fun SessionSpec.toCore(): CoreSpec {
    val lo = hrBandLow
    val hi = hrBandHigh
    require((lo == null) == (hi == null)) { "hrBandLow and hrBandHigh must be given together" }
    return CoreSpec(
        templateId = templateId,
        templateVersion = templateVersion.toInt(),
        name = name,
        warmupSeconds = warmupSeconds?.toInt(),
        cooldownSeconds = cooldownSeconds?.toInt(),
        lapLockout = lapLockout,
        autoStop = autoStop ?: false,
        cueProfile = CoreCueProfile.valueOf(cueProfile.name.toCamel()),
        hrBand = if (lo != null && hi != null) lo to hi else null,
        steps = steps.map { it.toCore() },
    )
}

/**
 * Throws [IllegalArgumentException] when the context breaks the contract (too many boards or
 * entries, an entry without its board's series); the caller then starts with no context.
 */
fun LiveContext.toCore(): CoreLiveContext = CoreLiveContext(
    boards = boards.map { b ->
        CoreLiveBoard(
            key = b.key,
            label = b.label,
            kind = CoreLiveBoardKind.valueOf(b.kind.name.toCamel()),
            targetM = b.targetM,
            entries = b.entries.map { e ->
                CoreLiveEntry(
                    runId = e.runId,
                    dateMs = e.dateMs,
                    fromStartSplitsMs = e.fromStartSplitsMs,
                    liveRepPacesSecPerKm = e.liveRepPacesSecPerKm,
                    cooperMinuteM = e.cooperMinuteM,
                    finalMetric = e.finalMetric,
                )
            },
        )
    },
    target = target?.let { CoreLiveTarget(it.distanceM, it.targetMs, it.predicted) },
    nudges = nudges?.let { n ->
        CoreNudgePlan(
            version = n.version.toInt(),
            fastStart = n.fastStart?.let { CoreFastStart(it.km1MaxMs, it.text) },
            repFade = n.repFade?.let { CoreRepFade(it.maxDropSecPerKm, it.text) },
            hrDrift = n.hrDrift?.let { h ->
                CoreHrDrift(
                    kmSamples = h.kmSamples.map { km -> km.map { require(it.size == 2) { "kmSamples pairs are [pace, hr]" }; it[0] to it[1] } },
                    bpmOver = h.bpmOver, paceBand = h.paceBand, firstKm = h.firstKm.toInt(), minSimilar = h.minSimilar.toInt(), text = h.text,
                )
            },
            blocked = n.blocked.orEmpty(),
        )
    },
    cooperCurve = cooperCurve,
    cooperHistory = cooperHistory,
    coachingMuted = coachingMuted,
    builtAtMs = builtAtMs,
    engineVersion = engineVersion.toInt(),
)
