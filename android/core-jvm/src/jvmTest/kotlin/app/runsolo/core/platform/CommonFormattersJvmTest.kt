package app.runsolo.core.platform

import java.time.Instant
import java.util.Locale
import kotlin.random.Random
import kotlin.test.Test
import kotlin.test.assertEquals

/** The pure-Kotlin versions the Apple actuals use, proven equal to the JVM calls they stand for. */
class CommonFormattersJvmTest {
    @Test
    fun fixed2MatchesStringFormat() {
        val r = Random(42)
        val values = ArrayList<Double>()
        repeat(200_000) { values += r.nextDouble(0.0, 60.0) } // km distances
        repeat(50_000) { values += r.nextInt(0, 60_000) / 1000.0 + 0.005 } // x.xx5 ties on the decimal digits
        repeat(20_000) { values += -r.nextDouble(0.0, 100.0) }
        repeat(20_000) { values += Double.fromBits(r.nextLong()).takeIf { it.isFinite() && kotlin.math.abs(it) < 1e30 } ?: 1.0 }
        values += listOf(0.0, -0.0, 0.005, 0.004999, 0.995, 9.995, 99.995, 1e-10, 1e7, 1.0E22)
        val bad = values.filter { commonFixed2(it) != String.format(Locale.US, "%.2f", it) }
        assertEquals(emptyList(), bad.take(10).map { "$it: ${commonFixed2(it)} vs ${String.format(Locale.US, "%.2f", it)}" })
    }

    @Test
    fun isoInstantMatchesJavaTime() {
        val r = Random(7)
        val values = ArrayList<Long>()
        repeat(200_000) { values += r.nextLong(0, 253_402_300_799_999L) } // to 9999-12-31
        repeat(10_000) { values += r.nextLong(0, 100_000) * 1000 } // whole seconds
        values += listOf(0L, 951_782_400_000L, 951_868_799_999L, 1_758_672_000_000L, 4_102_444_799_999L)
        for (v in values) {
            assertEquals(Instant.ofEpochMilli(v).toString(), commonIsoInstant(v), "$v")
            assertEquals(v, commonParseIsoInstant(commonIsoInstant(v)))
        }
    }

    @Test
    fun toRadiansMatchesMath() {
        val r = Random(3)
        repeat(100_000) {
            val d = r.nextDouble(-360.0, 360.0)
            assertEquals(Math.toRadians(d).toBits(), commonToRadians(d).toBits(), "$d")
        }
    }

    @Test
    fun toDegreesMatchesMath() {
        val r = Random(5)
        repeat(100_000) {
            val d = r.nextDouble(-7.0, 7.0)
            assertEquals(Math.toDegrees(d).toBits(), commonToDegrees(d).toBits(), "$d")
        }
    }

    @Test
    fun gzipRoundTrip() {
        val b = "x".repeat(10_000).encodeToByteArray()
        assertEquals(b.toList(), gunzip(gzip(b)).toList())
    }
}
