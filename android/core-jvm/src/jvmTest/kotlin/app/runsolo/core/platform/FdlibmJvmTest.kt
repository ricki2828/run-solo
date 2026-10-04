package app.runsolo.core.platform

import kotlin.random.Random
import kotlin.test.Test
import kotlin.test.assertEquals

/** The common fdlibm port must equal java.lang.StrictMath (which is fdlibm) bit for bit. */
class FdlibmJvmTest {
    private fun inputs(): List<Double> {
        val r = Random(20261004)
        val out = ArrayList<Double>()
        val specials = listOf(0.0, -0.0, 1e-310, 1e-30, 1e-9, 0.3, 0.5, 0.78125, Math.PI / 4, Math.PI / 2, Math.PI, 2 * Math.PI, 1.0, -1.0, 1.5, 2.4375)
        out += specials + specials.map { -it }
        for (n in 1..64) for (dx in -3..3) out += Math.nextAfter(n * Math.PI / 2, 0.0) + dx * Math.ulp(n * Math.PI / 2)
        repeat(400_000) { out += (r.nextDouble() * 2 - 1) * Math.PI } // |x| <= pi: what core passes
        repeat(100_000) { out += (r.nextDouble() * 2 - 1) * 800_000.0 } // medium reduction range (< 2^19 pi/2) // medium reduction range
        return out
    }

    @Test fun `sin and cos equal StrictMath`() {
        for (x in inputs()) {
            assertEquals(StrictMath.sin(x).toRawBits(), fdlibmSin(x).toRawBits(), "sin($x)")
            assertEquals(StrictMath.cos(x).toRawBits(), fdlibmCos(x).toRawBits(), "cos($x)")
        }
    }

    @Test fun `atan2 equals StrictMath`() {
        val r = Random(7)
        val xs = inputs().filter { kotlin.math.abs(it) < 1e30 }.take(150_000)
        val edge = listOf(0.0, -0.0, 1.0, -1.0, Double.POSITIVE_INFINITY, Double.NEGATIVE_INFINITY, Double.NaN, 1e-300, 1e300)
        for (y in edge) for (x in edge) assertEquals(StrictMath.atan2(y, x).toRawBits(), fdlibmAtan2(y, x).toRawBits(), "atan2($y, $x)")
        for (x in xs) {
            val y = x * r.nextDouble() * 4 - r.nextDouble()
            assertEquals(StrictMath.atan2(y, x).toRawBits(), fdlibmAtan2(y, x).toRawBits(), "atan2($y, $x)")
            val a = r.nextDouble(); val s = kotlin.math.sqrt(a); val c = kotlin.math.sqrt(1 - a) // haversine shape
            assertEquals(StrictMath.atan2(s, c).toRawBits(), fdlibmAtan2(s, c).toRawBits(), "atan2($s, $c)")
        }
    }
}
