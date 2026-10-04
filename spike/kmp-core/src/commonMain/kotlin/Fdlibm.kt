package app.runsolo.core.platform

import kotlin.math.abs

/*
 * fdlibm 5.3 sin/cos/atan2 (Sun Microsystems, freely redistributable), the algorithms behind
 * java.lang.StrictMath, in plain IEEE double arithmetic so every platform gets the same bits.
 * kotlin.math.sin/cos/atan2 call the platform libm on Native (Apple libm) and Math.* on the JVM;
 * the two differ in the last ulp (K0 trip 5), which moves distances and every fixture after them.
 *
 * Argument reduction covers |x| <= 2^19 * pi/2 (fdlibm's "medium" range); larger arguments throw.
 * Core only passes radians of latitudes, longitude deltas and half-deltas (|x| <= pi).
 */

private fun hi(x: Double): Int = (x.toRawBits() ushr 32).toInt()
private fun lo(x: Double): Int = x.toRawBits().toInt()
private fun d(bits: String): Double = Double.fromBits(bits.toULong(16).toLong())
private fun fromWords(hi: Int, lo: Int): Double = Double.fromBits((hi.toLong() shl 32) or (lo.toLong() and 0xffffffffL))

private val S1 = d("BFC5555555555549")
private val S2 = d("3F8111111110F8A6")
private val S3 = d("BF2A01A019C161D5")
private val S4 = d("3EC71DE357B1FE7D")
private val S5 = d("BE5AE5E68A2B9CEB")
private val S6 = d("3DE5D93A5ACFD57C")

private fun kernelSin(x: Double, y: Double, iy: Int): Double {
    val ix = hi(x) and 0x7fffffff
    if (ix < 0x3e400000 && x.toInt() == 0) return x // |x| < 2^-27
    val z = x * x
    val v = z * x
    val r = S2 + z * (S3 + z * (S4 + z * (S5 + z * S6)))
    return if (iy == 0) x + v * (S1 + z * r) else x - ((z * (0.5 * y - v * r) - y) - v * S1)
}

private val C1 = d("3FA555555555554C")
private val C2 = d("BF56C16C16C15177")
private val C3 = d("3EFA01A019CB1590")
private val C4 = d("BE927E4F809C52AD")
private val C5 = d("3E21EE9EBDB4B1C4")
private val C6 = d("BDA8FAE9BE8838D4")

private fun kernelCos(x: Double, y: Double): Double {
    val ix = hi(x) and 0x7fffffff
    if (ix < 0x3e400000 && x.toInt() == 0) return 1.0
    val z = x * x
    val r = z * (C1 + z * (C2 + z * (C3 + z * (C4 + z * (C5 + z * C6)))))
    if (ix < 0x3FD33333) return 1.0 - (0.5 * z - (z * r - x * y)) // |x| < 0.3
    val qx = if (ix > 0x3fe90000) 0.28125 else fromWords(ix - 0x00200000, 0)
    val hz = 0.5 * z - qx
    val a = 1.0 - qx
    return a - (hz - (z * r - x * y))
}

private val INVPIO2 = d("3FE45F306DC9C883")
private val PIO2_1 = d("3FF921FB54400000")
private val PIO2_1T = d("3DD0B4611A626331")
private val PIO2_2 = d("3DD0B4611A600000")
private val PIO2_2T = d("3BA3198A2E037073")
private val PIO2_3 = d("3BA3198A2E000000")
private val PIO2_3T = d("397B839A252049C1")

/** High words of n*pi/2, n = 1..32 (fdlibm npio2_hw): the quick no-cancellation check. */
private val NPIO2_HW = intArrayOf(
    0x3FF921FB, 0x400921FB, 0x4012D97C, 0x401921FB, 0x401F6A7A, 0x4022D97C,
    0x4025FDBB, 0x402921FB, 0x402C463A, 0x402F6A7A, 0x4031475C, 0x4032D97C,
    0x40346B9C, 0x4035FDBB, 0x40378FDB, 0x403921FB, 0x403AB41B, 0x403C463A,
    0x403DD85A, 0x403F6A7A, 0x40407E4C, 0x4041475C, 0x4042106C, 0x4042D97C,
    0x4043A28C, 0x40446B9C, 0x404534AC, 0x4045FDBB, 0x4046C6CB, 0x40478FDB,
    0x404858EB, 0x404921FB,
)

/** x = n*pi/2 + y[0] + y[1]; returns n. */
private fun remPio2(x: Double, y: DoubleArray): Int {
    val hx = hi(x)
    val ix = hx and 0x7fffffff
    if (ix <= 0x3fe921fb) { y[0] = x; y[1] = 0.0; return 0 }
    if (ix < 0x4002d97c) { // |x| < 3pi/4
        if (hx > 0) {
            var z = x - PIO2_1
            if (ix != 0x3ff921fb) {
                y[0] = z - PIO2_1T; y[1] = (z - y[0]) - PIO2_1T
            } else {
                z -= PIO2_2; y[0] = z - PIO2_2T; y[1] = (z - y[0]) - PIO2_2T
            }
            return 1
        } else {
            var z = x + PIO2_1
            if (ix != 0x3ff921fb) {
                y[0] = z + PIO2_1T; y[1] = (z - y[0]) + PIO2_1T
            } else {
                z += PIO2_2; y[0] = z + PIO2_2T; y[1] = (z - y[0]) + PIO2_2T
            }
            return -1
        }
    }
    require(ix <= 0x413921fb) { "fdlibm remPio2: |x| > 2^19*pi/2 not ported" }
    var t = abs(x)
    val n = (t * INVPIO2 + 0.5).toInt()
    val fn = n.toDouble()
    var r = t - fn * PIO2_1
    var w = fn * PIO2_1T
    if (n < 32 && ix != NPIO2_HW[n - 1]) {
        y[0] = r - w
    } else {
        val j = ix shr 20
        y[0] = r - w
        var i = j - ((hi(y[0]) shr 20) and 0x7ff)
        if (i > 16) {
            t = r
            w = fn * PIO2_2
            r = t - w
            w = fn * PIO2_2T - ((t - r) - w)
            y[0] = r - w
            i = j - ((hi(y[0]) shr 20) and 0x7ff)
            if (i > 49) {
                t = r
                w = fn * PIO2_3
                r = t - w
                w = fn * PIO2_3T - ((t - r) - w)
                y[0] = r - w
            }
        }
    }
    y[1] = (r - y[0]) - w
    if (hx < 0) { y[0] = -y[0]; y[1] = -y[1]; return -n }
    return n
}

fun sin(x: Double): Double {
    val ix = hi(x) and 0x7fffffff
    if (ix <= 0x3fe921fb) return kernelSin(x, 0.0, 0)
    if (ix >= 0x7ff00000) return x - x
    val y = DoubleArray(2)
    return when (remPio2(x, y) and 3) {
        0 -> kernelSin(y[0], y[1], 1)
        1 -> kernelCos(y[0], y[1])
        2 -> -kernelSin(y[0], y[1], 1)
        else -> -kernelCos(y[0], y[1])
    }
}

fun cos(x: Double): Double {
    val ix = hi(x) and 0x7fffffff
    if (ix <= 0x3fe921fb) return kernelCos(x, 0.0)
    if (ix >= 0x7ff00000) return x - x
    val y = DoubleArray(2)
    return when (remPio2(x, y) and 3) {
        0 -> kernelCos(y[0], y[1])
        1 -> -kernelSin(y[0], y[1], 1)
        2 -> -kernelCos(y[0], y[1])
        else -> kernelSin(y[0], y[1], 1)
    }
}

private val ATANHI = doubleArrayOf(
    d("3FDDAC670561BB4F"), d("3FE921FB54442D18"),
    d("3FEF730BD281F69B"), d("3FF921FB54442D18"),
)
private val ATANLO = doubleArrayOf(
    d("3C7A2B7F222F65E2"), d("3C81A62633145C07"),
    d("3C7007887AF0CBBD"), d("3C91A62633145C07"),
)
private val AT = listOf(
    "3FD555555555550D",
    "BFC999999998EBC4",
    "3FC24924920083FF",
    "BFBC71C6FE231671",
    "3FB745CDC54C206E",
    "BFB3B0F2AF749A6D",
    "3FB10D66A0D03D51",
    "BFADDE2D52DEFD9A",
    "3FA97B4B24760DEB",
    "BFA2B4442C6A6C2F",
    "3F90AD3AE322DA11",
).map(::d).toDoubleArray()

private fun atan(x0: Double): Double {
    var x = x0
    val hx = hi(x)
    val ix = hx and 0x7fffffff
    val id: Int
    if (ix >= 0x44100000) { // |x| >= 2^66
        if (ix > 0x7ff00000 || (ix == 0x7ff00000 && lo(x) != 0)) return x + x
        return if (hx > 0) ATANHI[3] + ATANLO[3] else -ATANHI[3] - ATANLO[3]
    }
    if (ix < 0x3fdc0000) { // |x| < 0.4375
        if (ix < 0x3e200000) return x // |x| < 2^-29
        id = -1
    } else {
        x = abs(x)
        if (ix < 0x3ff30000) {
            if (ix < 0x3fe60000) { id = 0; x = (2.0 * x - 1.0) / (2.0 + x) } else { id = 1; x = (x - 1.0) / (x + 1.0) }
        } else {
            if (ix < 0x40038000) { id = 2; x = (x - 1.5) / (1.0 + 1.5 * x) } else { id = 3; x = -1.0 / x }
        }
    }
    val z = x * x
    val w = z * z
    val s1 = z * (AT[0] + w * (AT[2] + w * (AT[4] + w * (AT[6] + w * (AT[8] + w * AT[10])))))
    val s2 = w * (AT[1] + w * (AT[3] + w * (AT[5] + w * (AT[7] + w * AT[9]))))
    if (id < 0) return x - x * (s1 + s2)
    val r = ATANHI[id] - ((x * (s1 + s2) - ATANLO[id]) - x)
    return if (hx < 0) -r else r
}

private val PI_O_4 = d("3FE921FB54442D18")
private val PI_O_2 = d("3FF921FB54442D18")
private val PI = d("400921FB54442D18")
private val PI_LO = d("3CA1A62633145C07")
private const val TINY = 1.0e-300

fun atan2(y: Double, x: Double): Double {
    if (x.isNaN() || y.isNaN()) return x + y
    val hx = hi(x); val ix = hx and 0x7fffffff; val lx = lo(x)
    val hy = hi(y); val iy = hy and 0x7fffffff; val ly = lo(y)
    if (((hx - 0x3ff00000) or lx) == 0) return atan(y) // x = 1.0
    val m = ((hy shr 31) and 1) or ((hx shr 30) and 2)
    if ((iy or ly) == 0) {
        return when (m) { 0, 1 -> y; 2 -> PI + TINY; else -> -PI - TINY }
    }
    if ((ix or lx) == 0) return if (hy < 0) -PI_O_2 - TINY else PI_O_2 + TINY
    if (ix == 0x7ff00000) {
        return if (iy == 0x7ff00000) {
            when (m) { 0 -> PI_O_4 + TINY; 1 -> -PI_O_4 - TINY; 2 -> 3.0 * PI_O_4 + TINY; else -> -3.0 * PI_O_4 - TINY }
        } else {
            when (m) { 0 -> 0.0; 1 -> -0.0; 2 -> PI + TINY; else -> -PI - TINY }
        }
    }
    if (iy == 0x7ff00000) return if (hy < 0) -PI_O_2 - TINY else PI_O_2 + TINY
    val k = (iy - ix) shr 20
    val z = when {
        k > 60 -> PI_O_2 + 0.5 * PI_LO
        hx < 0 && k < -60 -> 0.0
        else -> atan(abs(y / x))
    }
    return when (m) {
        0 -> z
        1 -> -z
        2 -> PI - (z - PI_LO)
        else -> (z - PI_LO) - PI
    }
}
