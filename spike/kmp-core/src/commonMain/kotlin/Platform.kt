package app.runsolo.core.platform

import kotlin.math.abs

/** gzip with the JVM's defaults (deflate level 6, gzip wrapper). Byte-identical output is not promised. */
expect fun gzip(bytes: ByteArray): ByteArray

expect fun gunzip(bytes: ByteArray): ByteArray

/** JVM: java.io.IOException (typealias), so JVM catch sites keep their meaning. */
expect open class IOException(message: String?) : Exception

expect class FileNotFoundException(message: String?) : IOException

/** Double.toString as the JVM writes it into journals and run files. Native: see appleMain. */
expect fun formatDouble(d: Double): String

/** JDK 9+ Math.toRadians: a multiply by the rounded constant, not `/ 180 * PI` (different last bit). */
fun toRadians(deg: Double): Double = deg * 0.017453292519943295

/**
 * `String.format(Locale.US, "%.2f", d)`. Java's Formatter rounds HALF_UP on the decimal digits of
 * Double.toString (so 1.005 -> "1.01", where C printf gives "1.00"), so this rounds the
 * [formatDouble] digits, not the binary value.
 */
fun fixed2(d: Double): String {
    require(d.isFinite())
    val neg = d < 0 || (d == 0.0 && 1.0 / d < 0)
    val (digits, exp) = decimalDigits(abs(d)) // value = 0.digits * 10^exp
    // Integer of round(value * 100) as a digit string, HALF_UP on the decimal expansion.
    val keep = exp + 2 // digits before the cut
    val sb = StringBuilder()
    when {
        keep <= 0 -> {
            val roundUp = keep == 0 && digits[0] >= '5'
            sb.append(if (roundUp) "1" else "0")
        }
        else -> {
            val head = if (keep <= digits.length) digits.substring(0, keep) else digits.padEnd(keep, '0')
            val roundUp = keep < digits.length && digits[keep] >= '5'
            sb.append(if (roundUp) incrementDigits(head) else head)
        }
    }
    val n = sb.toString().trimStart('0').ifEmpty { "0" }.padStart(3, '0')
    val out = n.substring(0, n.length - 2) + "." + n.substring(n.length - 2)
    return if (neg) "-$out" else out
}

private fun incrementDigits(s: String): String {
    val c = s.toCharArray()
    var i = c.size - 1
    while (i >= 0) {
        if (c[i] == '9') { c[i] = '0'; i-- } else { c[i] = c[i] + 1; return c.concatToString() }
    }
    return "1" + c.concatToString()
}

/** Significant digits (no leading/trailing zeros) and decimal exponent of [formatDouble]: value = 0.D * 10^exp. */
private fun decimalDigits(d: Double): Pair<String, Int> {
    if (d == 0.0) return "0" to 1
    val s = formatDouble(d)
    val ePos = s.indexOfFirst { it == 'E' || it == 'e' }
    val mant = if (ePos >= 0) s.substring(0, ePos) else s
    val e10 = if (ePos >= 0) s.substring(ePos + 1).toInt() else 0
    val dot = mant.indexOf('.')
    val intPart = if (dot >= 0) mant.substring(0, dot) else mant
    val frac = if (dot >= 0) mant.substring(dot + 1) else ""
    val all = intPart + frac
    val lead = all.indexOfFirst { it != '0' }
    val digits = all.substring(lead).trimEnd('0')
    return digits to (intPart.length - lead + e10)
}

/** `Instant.ofEpochMilli(ms).toString()` (ISO_INSTANT): seconds always, `.SSS` only when ms != 0. Years 0..9999. */
fun isoInstant(epochMs: Long): String {
    val days = epochMs.floorDiv(86_400_000L)
    val msOfDay = epochMs - days * 86_400_000L
    val (y, m, d) = civilFromDays(days)
    require(y in 0..9999) { "year out of range: $y" }
    val h = msOfDay / 3_600_000
    val min = msOfDay / 60_000 % 60
    val s = msOfDay / 1000 % 60
    val ms = msOfDay % 1000
    val sb = StringBuilder()
    sb.append(y.toString().padStart(4, '0')).append('-').append(p2(m)).append('-').append(p2(d))
    sb.append('T').append(p2(h)).append(':').append(p2(min)).append(':').append(p2(s))
    if (ms != 0L) sb.append('.').append(ms.toString().padStart(3, '0'))
    return sb.append('Z').toString()
}

/** Inverse of [isoInstant] for the forms it writes (tests). */
fun parseIsoInstant(s: String): Long {
    val r = Regex("""(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})(?:\.(\d{1,9}))?Z""").matchEntire(s)
        ?: throw IllegalArgumentException("not an ISO instant: $s")
    val g = r.groupValues
    val days = daysFromCivil(g[1].toLong(), g[2].toLong(), g[3].toLong())
    val ms = if (g[7].isEmpty()) 0L else g[7].padEnd(9, '0').substring(0, 3).toLong()
    return days * 86_400_000L + g[4].toLong() * 3_600_000 + g[5].toLong() * 60_000 + g[6].toLong() * 1000 + ms
}

private fun p2(v: Long) = v.toString().padStart(2, '0')

// Howard Hinnant's civil_from_days / days_from_civil (proleptic Gregorian, as java.time).
private fun civilFromDays(z0: Long): Triple<Long, Long, Long> {
    val z = z0 + 719_468
    val era = (if (z >= 0) z else z - 146_096) / 146_097
    val doe = z - era * 146_097
    val yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365
    val y = yoe + era * 400
    val doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
    val mp = (5 * doy + 2) / 153
    val d = doy - (153 * mp + 2) / 5 + 1
    val m = if (mp < 10) mp + 3 else mp - 9
    return Triple(if (m <= 2) y + 1 else y, m, d)
}

private fun daysFromCivil(y0: Long, m: Long, d: Long): Long {
    val y = if (m <= 2) y0 - 1 else y0
    val era = (if (y >= 0) y else y - 399) / 400
    val yoe = y - era * 400
    val doy = (153 * (if (m > 2) m - 3 else m + 9) + 2) / 5 + d - 1
    val doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
    return era * 146_097 + doe - 719_468
}

/** Wall clock in epoch millis (System.currentTimeMillis on the JVM). */
expect fun currentTimeMillis(): Long
