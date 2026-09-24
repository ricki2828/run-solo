package app.runsolo.platform

import app.runsolo.core.model.CueKind as CoreCue
import app.runsolo.core.model.LapSource as CoreLapSource
import app.runsolo.core.model.Phase as CorePhase
import app.runsolo.core.model.Preset as CorePreset
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
fun CorePreset.toPigeon(): Preset = Preset(reps = reps.toLong(), workSeconds = workSeconds.toLong(), recoverySeconds = recoverySeconds.toLong())
fun Preset.toCore(): CorePreset = CorePreset(reps = reps.toInt(), workSeconds = workSeconds.toInt(), recoverySeconds = recoverySeconds.toInt())
