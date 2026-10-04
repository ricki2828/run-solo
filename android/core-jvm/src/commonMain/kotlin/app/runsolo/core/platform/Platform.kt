package app.runsolo.core.platform

/*
 * The JVM-only calls core used to make directly (plan K1). On the JVM each actual is the exact
 * call it replaces, so Android behaviour is unchanged; Apple actuals use CommonFormat.kt,
 * Fdlibm.kt and POSIX/zlib.
 */

/** gzip with the gzip wrapper (GZIPOutputStream on the JVM). Byte-identical output across platforms is not promised. */
expect fun gzip(bytes: ByteArray): ByteArray

expect fun gunzip(bytes: ByteArray): ByteArray

/** `String.toByteArray(Charsets.UTF_8)`: the JVM replaces malformed input differently from encodeToByteArray. */
expect fun encodeUtf8(s: String): ByteArray

/** `String(bytes, Charsets.UTF_8)`. */
expect fun decodeUtf8(bytes: ByteArray): String

/** JVM: java.io.IOException (typealias), so JVM catch sites keep their meaning. */
expect open class IOException(message: String?) : Exception

expect class FileNotFoundException(message: String?) : IOException

/** `Double.toString` as the JVM writes it into journals and run files. */
expect fun formatDouble(d: Double): String

/** `String.format(Locale.US, "%.2f", d)`. */
expect fun fixed2(d: Double): String

/** `Instant.ofEpochMilli(epochMs).toString()`. */
expect fun isoInstant(epochMs: Long): String

/** `Instant.parse(s).toEpochMilli()` for the forms [isoInstant] writes. */
expect fun parseIsoInstant(s: String): Long

expect fun toRadians(deg: Double): Double

expect fun toDegrees(rad: Double): Double

/**
 * Trig used for distances. The JVM keeps `Math.*`; Apple uses fdlibm (= StrictMath), because
 * Apple libm rounds differently in the last ulp and every distance and fixture after it moves.
 */
expect fun sin(x: Double): Double

expect fun cos(x: Double): Double

expect fun atan2(y: Double, x: Double): Double

/** Wall clock in epoch millis (`System.currentTimeMillis` on the JVM). */
expect fun currentTimeMillis(): Long
