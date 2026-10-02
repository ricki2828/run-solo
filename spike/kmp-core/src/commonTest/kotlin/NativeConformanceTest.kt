package app.runsolo.core.spike

import app.runsolo.core.contract.ContractFixtures
import app.runsolo.core.contract.EventTraceFixture
import app.runsolo.core.contract.TranscriptFixture
import app.runsolo.core.contract.VoiceCopyFixture
import app.runsolo.core.fs.FileSystem
import app.runsolo.core.json.Json
import app.runsolo.core.platform.fixed2
import app.runsolo.core.platform.formatDouble
import app.runsolo.core.platform.isoInstant
import app.runsolo.core.platform.parseIsoInstant
import app.runsolo.core.testio.CORE_JVM_DIR
import app.runsolo.core.testio.File
import app.runsolo.core.testio.TEST_PLATFORM
import app.runsolo.core.testio.testMkdirs
import app.runsolo.core.testio.testWriteBytes
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

/**
 * K0: every generated fixture against its checked-in (JVM-written) file. Parsed JSON must be equal
 * (asserted); byte differences are listed in build/reports/conformance/<platform>.txt, not failed,
 * so one run shows all of them. The original byte-for-byte tests run too and fail on any diff.
 */
class NativeConformanceTest {
    private val report = StringBuilder()

    private fun numbers(s: String) = Regex("""-?\d+(?:\.\d+)?(?:[eE][-+]?\d+)?""").findAll(s).map { it.value }.toList()

    /** Compares one fixture; returns true when parsed-equal. */
    private fun check(name: String, generated: String, checkedIn: String, parse: (String) -> Any?): Boolean {
        val parsedEqual = try { parse(generated) == parse(checkedIn) } catch (e: Exception) { report.appendLine("  $name: PARSE ERROR $e"); false }
        if (generated == checkedIn) {
            report.appendLine("  $name: bytes equal")
            return parsedEqual
        }
        val a = numbers(generated)
        val b = numbers(checkedIn)
        val diffs = a.zip(b).filter { (x, y) -> x != y }
        report.appendLine("  $name: BYTES DIFFER (parsed equal=$parsedEqual) len ${generated.length} vs ${checkedIn.length}, number tokens ${a.size} vs ${b.size}, differing ${diffs.size}; first: ${diffs.take(5).joinToString { "native=${it.first} jvm=${it.second}" }}")
        return parsedEqual
    }

    private fun ndjson(s: String) = s.lineSequence().filter { it.isNotBlank() }.map { Json.parse(it) }.toList()

    @Test
    fun fixturesParsedEqual() {
        val failed = ArrayList<String>()
        report.appendLine("# K0 conformance on $TEST_PLATFORM")
        report.appendLine("contract run files (ContractFixtures, schema 3):")
        for ((name, json) in ContractFixtures.all()) {
            if (!check(name, json + "\n", File(ContractFixtures.DIR, "$name.json").readText()) { Json.parse(it) }) failed += name
        }
        report.appendLine("transcripts (TranscriptFixture):")
        for ((kind, json) in TranscriptFixture.all()) {
            if (!check(kind, json + "\n", File(TranscriptFixture.DIR, "$kind.json").readText()) { Json.parse(it) }) failed += kind
        }
        report.appendLine("event trace (EventTraceFixture, ndjson):")
        val ev = File(EventTraceFixture.DIR, "${EventTraceFixture.NAME}.ndjson").readText()
        if (!check(EventTraceFixture.NAME, EventTraceFixture.generate(), ev) { ndjson(it) }) failed += EventTraceFixture.NAME
        report.appendLine("voice copy (VoiceCopyFixture, tsv, text only):")
        val vc = File(VoiceCopyFixture.FILE).readText()
        if (!check("voice_copy", VoiceCopyFixture.render(), vc) { it }) failed += "voice_copy"
        report.appendLine("parsed-equal failures: ${failed.size} $failed")
        doubleProbe()
        writeReport()
        assertTrue(failed.isEmpty(), "parsed JSON differs: $failed")
    }

    /** Double.toString vs the JVM: every fraction token in the checked-in fixtures plus JDK 17 edge cases. */
    private fun doubleProbe() {
        val dir = File(ContractFixtures.DIR)
        val files = (dir.listFiles { it.name.endsWith(".json") }!!.toList() +
            File(TranscriptFixture.DIR).listFiles()!!.toList() +
            File(EventTraceFixture.DIR).listFiles()!!.toList())
        var total = 0
        val bad = ArrayList<String>()
        for (f in files) for (tok in numbers(f.readText())) {
            if ('.' !in tok && 'E' !in tok) continue
            total++
            val got = formatDouble(tok.toDouble())
            if (got != tok) bad += "$tok -> $got (${f.name})"
        }
        report.appendLine("double probe: $total fraction tokens from fixtures, ${bad.size} print differently: ${bad.take(10)}")
        var edgeBad = 0
        for ((hex, exp) in EDGES) {
            val d = Double.fromBits(hex.toULong(16).toLong())
            val ts = formatDouble(d)
            val f2 = fixed2(d)
            if (ts != exp.first || f2 != exp.second) {
                edgeBad++
                report.appendLine("  edge $hex: toString native=$ts jvm=${exp.first}; %.2f common=$f2 jvm=${exp.second}")
            }
        }
        report.appendLine("edge doubles: ${EDGES.size}, differing $edgeBad")
        val instants = listOf(0L, 1_758_672_000_000L, 1_758_672_000_123L, 1_758_672_003_001L, 951_782_400_000L, 4_102_444_799_999L)
        val iso = instants.map { isoInstant(it) }
        report.appendLine("iso instants: $iso")
        assertEquals(instants, iso.map { parseIsoInstant(it) })
    }

    private fun writeReport() {
        val dir = "$CORE_JVM_DIR/../../spike/kmp-core/build/reports/conformance"
        testMkdirs(dir)
        testWriteBytes("$dir/$TEST_PLATFORM.txt", report.toString().encodeToByteArray())
        println(report)
    }

    @Test
    fun replayThroughSpikePipelineMatchesFixture() {
        val mem = app.runsolo.core.fs.FakeFileSystem()
        val json = SpikeReplay.runFileJson("4x4", mem)
        assertEquals(Json.parse(File(ContractFixtures.DIR, "replay_4x4.json").readText()), Json.parse(json))
    }

    companion object {
        // JDK 17 Double.toString and String.format(Locale.US, "%.2f") for these bit patterns.
        val EDGES: Map<String, Pair<String, String>> = linkedMapOf(
        "3fb999999999999a" to ("0.1" to "0.10"),
        "3fd3333333333334" to ("0.30000000000000004" to "0.30"),
        "3fd5555555555555" to ("0.3333333333333333" to "0.33"),
        "3fe5555555555555" to ("0.6666666666666666" to "0.67"),
        "3f50624dd2f1a9fc" to ("0.001" to "0.00"),
        "3f5061e273273f09" to ("9.999E-4" to "0.00"),
        "3ee4f8b588e368f1" to ("1.0E-5" to "0.00"),
        "3e8421f5f40d8376" to ("1.5E-7" to "0.00"),
        "416312d000000000" to ("1.0E7" to "10000000.00"),
        "416312d010000000" to ("1.00000005E7" to "10000000.50"),
        "416312cffff7ced9" to ("9999999.999" to "10000000.00"),
        "40fe240c9fbe76c9" to ("123456.789" to "123456.79"),
        "438f67ea69ed3795" to ("2.82879384806159008E17" to "282879384806159008.00"),
        "44b52d02c7e14af6" to ("9.999999999999999E22" to "99999999999999990000000.00"),
        "44c52d02c7e14af6" to ("1.9999999999999998E23" to "199999999999999980000000.00"),
        "1" to ("4.9E-324" to "0.00"),
        "4011666666666666" to ("4.35" to "4.35"),
        "c040ef34d6a161e5" to ("-33.8688" to "-33.87"),
        "4062e6b295e9e1b1" to ("151.2093" to "151.21"),
        "c040ef353e3186a6" to ("-33.868812345678904" to "-33.87"),
        "4062e6b2f5b58e12" to ("151.20934567890123" to "151.21"),
        "4010cccccccccccd" to ("4.2" to "4.20"),
        "3fb1eb851eb851ec" to ("0.07" to "0.07"),
        "4040aaaaaaaaaaab" to ("33.333333333333336" to "33.33"),
        "430c6bf526340002" to ("1.0000000000000002E15" to "1000000000000000.20"),
        "4341c37937e08000" to ("1.0E16" to "10000000000000000.00"),
        "4008000000000001" to ("3.0000000000000004" to "3.00"),
        "3fd3333333333334" to ("0.30000000000000004" to "0.30"),
        "3ff199999999999a" to ("1.1" to "1.10"),
        "4005666666666666" to ("2.675" to "2.68"),
        "3ff0147ae147ae14" to ("1.005" to "1.01"),
        "4020b0a3d70a3d71" to ("8.345" to "8.35"),
        "3f8999999999999a" to ("0.0125" to "0.01"),
        "3f12599ed7c6fbd3" to ("7.000000000000001E-5" to "0.00"),
        )
    }
}
