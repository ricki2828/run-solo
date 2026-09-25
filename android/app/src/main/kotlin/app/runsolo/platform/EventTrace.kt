package app.runsolo.platform

import android.util.Log
import app.runsolo.BuildConfig
import app.runsolo.core.json.Json

/**
 * Debug builds only: every event the EventChannel emits, plus a `status()` snapshot after each
 * state/phase event, logged as one NDJSON line under `RunSolo/trace` in the same shape as the
 * JVM-generated contract fixture (`contract-events/` NDJSON: `{"t": elapsedMs, "kind": …,
 * Pigeon field names, enums as their Dart names}`). The CI lifecycle run captures these lines
 * and `tools/check_event_trace.py` compares their structure with the fixture, so a mapping bug
 * on the Android side (a field missing, an enum spelt differently, a wrong `tMs` base) fails CI.
 */
/** Dart spelling of Pigeon enum constants, usable outside debug-only code. */
object EventTraceName {
    fun dart(e: Enum<*>): String = buildString {
        var up = false
        for (c in e.name) {
            if (c == '_') { up = true; continue }
            append(if (up) c.uppercaseChar() else c.lowercaseChar())
            up = false
        }
    }
}

object EventTrace {
    const val TAG = "RunSolo/trace"
    val enabled: Boolean get() = BuildConfig.REPLAY_ENABLED

    /** Dart enum spelling of a Pigeon Kotlin enum constant: `EQUAL_TO_PREVIOUS_WORK` → `equalToPreviousWork`. */
    fun dartName(e: Enum<*>): String = EventTraceName.dart(e)

    fun event(e: RecorderEvent, elapsedMs: Long) {
        if (!BuildConfig.REPLAY_ENABLED) return
        val m = LinkedHashMap<String, Any?>()
        // `t` is the event's own time where it has one (a tick's elapsedMs, a lap's tMs) — the
        // fixture does the same — and the elapsed time at emission for the others.
        m["t"] = when (e) {
            is TickEvent -> e.elapsedMs
            is LapEvent -> e.tMs
            else -> elapsedMs
        }
        when (e) {
            is TickEvent -> {
                m["kind"] = "tick"
                m["elapsedMs"] = e.elapsedMs
                m["lapElapsedMs"] = e.lapElapsedMs
                m["lapDistanceM"] = e.lapDistanceM
                m["lapPaceLiveSecPerKm"] = e.lapPaceLiveSecPerKm
                m["totalDistanceM"] = e.totalDistanceM
                m["hr"] = e.hr
                m["gpsAccuracyM"] = e.gpsAccuracyM
                m["state"] = dartName(e.state)
                m["phase"] = dartName(e.phase)
                m["repIndex"] = e.repIndex
                m["phaseRemainingMs"] = e.phaseRemainingMs
            }
            is LapEvent -> {
                m["kind"] = "lap"
                m["index"] = e.index
                m["tMs"] = e.tMs
                m["activeMs"] = e.activeMs
                m["distanceM"] = e.distanceM
                m["source"] = dartName(e.source)
            }
            is PhaseEvent -> {
                m["kind"] = "phase"
                m["phase"] = dartName(e.phase)
                m["repIndex"] = e.repIndex
                m["phaseDurationMs"] = e.phaseDurationMs
            }
            is StateEvent -> {
                m["kind"] = "state"
                m["state"] = dartName(e.state)
                m["runId"] = e.runId
                m["phase"] = dartName(e.phase)
            }
            is CueEvent -> {
                m["kind"] = "cue"
                m["cue"] = dartName(e.kind)
                m["value"] = e.value
            }
            is FaultEvent -> {
                m["kind"] = "fault"
                m["fault"] = dartName(e.kind)
                m["message"] = e.message
            }
        }
        Log.i(TAG, Json.write(m))
    }

    fun status(s: RecorderStatus, elapsedMs: Long) {
        if (!BuildConfig.REPLAY_ENABLED) return
        val m = LinkedHashMap<String, Any?>()
        m["t"] = elapsedMs
        m["kind"] = "status"
        m["state"] = dartName(s.state)
        m["runId"] = s.runId
        m["mode"] = dartName(s.mode)
        m["laps"] = s.laps.map { l ->
            linkedMapOf("index" to l.index, "tMs" to l.tMs, "activeMs" to l.activeMs, "distanceM" to l.distanceM, "source" to dartName(l.source))
        }
        m["elapsedMs"] = s.elapsedMs
        m["lapIndex"] = s.lapIndex
        m["gpsFix"] = s.gpsFix
        m["hrConnected"] = s.hrConnected
        m["phase"] = dartName(s.phase)
        m["repIndex"] = s.repIndex
        m["phaseRemainingMs"] = s.phaseRemainingMs
        m["spec"] = s.spec?.let { spec ->
            linkedMapOf(
                "templateId" to spec.templateId, "templateVersion" to spec.templateVersion, "name" to spec.name,
                "warmupSeconds" to spec.warmupSeconds, "cooldownSeconds" to spec.cooldownSeconds,
                "lapLockout" to spec.lapLockout, "autoStop" to spec.autoStop, "cueProfile" to dartName(spec.cueProfile),
                "hrBandLow" to spec.hrBandLow, "hrBandHigh" to spec.hrBandHigh,
                "steps" to spec.steps.map { st ->
                    linkedMapOf("kind" to dartName(st.kind), "target" to dartName(st.target), "value" to st.value, "style" to dartName(st.style), "repIndex" to st.repIndex)
                },
            )
        }
        m["stepIndex"] = s.stepIndex
        m["stepRemainingMs"] = s.stepRemainingMs
        m["stepRemainingM"] = s.stepRemainingM
        m["journalOk"] = s.journalOk
        Log.i(TAG, Json.write(m))
    }
}
