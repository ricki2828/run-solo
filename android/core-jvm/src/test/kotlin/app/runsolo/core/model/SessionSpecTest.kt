package app.runsolo.core.model

import app.runsolo.core.json.Json
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

/** The I1 contract's validation rules and JSON shape (Phase 3 §3.3); the Dart side applies the same table. */
class SessionSpecTest {
    private fun work(target: TargetKind, value: Int, rep: Int) = Step(StepKind.work, target, value, RecoveryStyle.run, rep)
    private fun rec(target: TargetKind, value: Int, rep: Int, style: RecoveryStyle = RecoveryStyle.jog) = Step(StepKind.recovery, target, value, style, rep)
    private fun spec(vararg steps: Step) = SessionSpec.norwegian4x4().copy(templateId = "custom:t", steps = steps.toList())
    private fun valid(s: SessionSpec) = assertEquals(emptyList(), s.problems(), s.toString())
    private fun invalid(s: SessionSpec) = assertTrue(s.problems().isNotEmpty(), "expected invalid: $s")

    @Test
    fun `presets and migration specs are valid`() {
        valid(SessionSpec.norwegian4x4())
        for (reps in 1..6) valid(SessionSpec.norwegian4x4(reps, 240, 180))
        valid(SessionSpec.COOPER)
        valid(SessionSpec.FARTLEK)
    }

    @Test
    fun `validation table`() {
        // Work: time 15..1200 s, distance 100..10000 m, never equal-time.
        valid(spec(work(TargetKind.time, 15, 1)))
        valid(spec(work(TargetKind.time, 1200, 1)))
        invalid(spec(work(TargetKind.time, 14, 1)))
        invalid(spec(work(TargetKind.time, 1201, 1)))
        valid(spec(work(TargetKind.distance, 100, 1)))
        valid(spec(work(TargetKind.distance, 10_000, 1)))
        invalid(spec(work(TargetKind.distance, 99, 1)))
        invalid(spec(work(TargetKind.distance, 10_001, 1)))
        invalid(spec(work(TargetKind.equalToPreviousWork, 0, 1)))
        // Recovery: time 0..600 s, distance 50..2000 m (jog only), equal-time value 0; walk/stand never by distance.
        valid(spec(work(TargetKind.time, 60, 1), rec(TargetKind.time, 0, 1), work(TargetKind.time, 60, 2)))
        valid(spec(work(TargetKind.time, 60, 1), rec(TargetKind.time, 600, 1, RecoveryStyle.stand), work(TargetKind.time, 60, 2)))
        invalid(spec(work(TargetKind.time, 60, 1), rec(TargetKind.time, 601, 1), work(TargetKind.time, 60, 2)))
        valid(spec(work(TargetKind.distance, 400, 1), rec(TargetKind.distance, 50, 1), work(TargetKind.distance, 400, 2)))
        invalid(spec(work(TargetKind.distance, 400, 1), rec(TargetKind.distance, 49, 1), work(TargetKind.distance, 400, 2)))
        invalid(spec(work(TargetKind.distance, 400, 1), rec(TargetKind.distance, 2001, 1), work(TargetKind.distance, 400, 2)))
        invalid(spec(work(TargetKind.distance, 400, 1), rec(TargetKind.distance, 200, 1, RecoveryStyle.walk), work(TargetKind.distance, 400, 2)))
        invalid(spec(work(TargetKind.distance, 400, 1), rec(TargetKind.distance, 200, 1, RecoveryStyle.stand), work(TargetKind.distance, 400, 2)))
        valid(spec(work(TargetKind.distance, 800, 1), rec(TargetKind.equalToPreviousWork, 0, 1, RecoveryStyle.walk), work(TargetKind.distance, 800, 2)))
        invalid(spec(work(TargetKind.distance, 800, 1), rec(TargetKind.equalToPreviousWork, 5, 1), work(TargetKind.distance, 800, 2)))
        invalid(spec(work(TargetKind.time, 60, 1), rec(TargetKind.time, 60, 1, RecoveryStyle.run), work(TargetKind.time, 60, 2)))
        // Structure: alternate, start and end with work, reps numbered, 1..40 work steps, ≤ 80 steps.
        invalid(spec(work(TargetKind.time, 60, 1), rec(TargetKind.time, 60, 1)))
        invalid(spec(rec(TargetKind.time, 60, 1), work(TargetKind.time, 60, 1)))
        invalid(spec(work(TargetKind.time, 60, 1), work(TargetKind.time, 60, 2)))
        invalid(spec(work(TargetKind.time, 60, 1), rec(TargetKind.time, 60, 2), work(TargetKind.time, 60, 2)))
        invalid(spec(work(TargetKind.time, 60, 2)))
        invalid(spec())
        val forty = (1..40).flatMap { r -> if (r < 40) listOf(work(TargetKind.time, 15, r), rec(TargetKind.time, 0, r)) else listOf(work(TargetKind.time, 15, r)) }
        valid(spec(*forty.toTypedArray()))
        val fortyOne = (1..41).flatMap { r -> if (r < 41) listOf(work(TargetKind.time, 15, r), rec(TargetKind.time, 0, r)) else listOf(work(TargetKind.time, 15, r)) }
        invalid(spec(*fortyOne.toTypedArray()))
        // HR band: 0 < low < high <= 1.2 (the Dart table).
        invalid(SessionSpec.norwegian4x4().copy(hrBand = 0.95 to 0.85))
        valid(SessionSpec.norwegian4x4().copy(hrBand = 0.85 to 1.2))
        invalid(SessionSpec.norwegian4x4().copy(hrBand = 0.85 to 1.21))
        // Warm-up / cool-down: open, or fixed 300..1200 s.
        valid(SessionSpec.norwegian4x4().copy(warmupSeconds = 300, cooldownSeconds = 1200))
        invalid(SessionSpec.norwegian4x4().copy(warmupSeconds = 299))
        invalid(SessionSpec.norwegian4x4().copy(cooldownSeconds = 1201))
        // Fartlek may be steps-empty; nothing else may.
        invalid(SessionSpec.FARTLEK.copy(templateId = "custom:x"))
    }

    @Test
    fun `canonical JSON - key order, flat steps, round trip`() {
        val text = Json.write(SessionSpec.norwegian4x4(3, 240, 150).toJson())
        assertEquals(
            """{"templateId":"norwegian-4x4","templateVersion":1,"name":"Norwegian 4x4","warmupSeconds":null,"cooldownSeconds":null,""" +
                """"lapLockout":false,"cueProfile":"standard","hrBand":[0.85,0.95],"steps":[""" +
                """{"kind":"work","target":"time","value":240,"style":"run","rep":1},""" +
                """{"kind":"recovery","target":"time","value":150,"style":"jog","rep":1},""" +
                """{"kind":"work","target":"time","value":240,"style":"run","rep":2},""" +
                """{"kind":"recovery","target":"time","value":150,"style":"jog","rep":2},""" +
                """{"kind":"work","target":"time","value":240,"style":"run","rep":3}]}""",
            text,
        )
        for (s in listOf(SessionSpec.norwegian4x4(), SessionSpec.COOPER, SessionSpec.FARTLEK)) {
            assertEquals(s, SessionSpec.fromJson(Json.parseObject(Json.write(s.toJson()))))
        }
        assertEquals(
            """{"templateId":"cooper","templateVersion":1,"name":"12-minute test","warmupSeconds":null,"cooldownSeconds":null,""" +
                """"lapLockout":true,"cueProfile":"cooper","hrBand":null,"steps":[{"kind":"work","target":"time","value":720,"style":"run","rep":1}]}""",
            Json.write(SessionSpec.COOPER.toJson()),
        )
    }

    @Test
    fun `legacy preset mapping`() {
        assertEquals(SessionSpec.norwegian4x4(6, 240, 300), SessionSpec.fromLegacyPreset(mapOf("reps" to 6L, "workSeconds" to 240L, "recoverySeconds" to 300L)))
    }
}
