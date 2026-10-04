package app.runsolo.core.platform

import java.io.ByteArrayOutputStream
import java.time.Instant
import java.util.Locale
import java.util.zip.GZIPInputStream
import java.util.zip.GZIPOutputStream

actual fun gzip(bytes: ByteArray): ByteArray {
    val out = ByteArrayOutputStream()
    GZIPOutputStream(out).use { it.write(bytes) }
    return out.toByteArray()
}

actual fun gunzip(bytes: ByteArray): ByteArray = GZIPInputStream(bytes.inputStream()).readBytes()

actual fun encodeUtf8(s: String): ByteArray = s.toByteArray(Charsets.UTF_8)

actual fun decodeUtf8(bytes: ByteArray): String = bytes.toString(Charsets.UTF_8)

actual typealias IOException = java.io.IOException

actual typealias FileNotFoundException = java.io.FileNotFoundException

actual fun formatDouble(d: Double): String = d.toString()

actual fun fixed2(d: Double): String = String.format(Locale.US, "%.2f", d)

actual fun isoInstant(epochMs: Long): String = Instant.ofEpochMilli(epochMs).toString()

actual fun parseIsoInstant(s: String): Long = Instant.parse(s).toEpochMilli()

actual fun toRadians(deg: Double): Double = Math.toRadians(deg)

actual fun toDegrees(rad: Double): Double = Math.toDegrees(rad)

actual fun sin(x: Double): Double = Math.sin(x)

actual fun cos(x: Double): Double = Math.cos(x)

actual fun atan2(y: Double, x: Double): Double = Math.atan2(y, x)

actual fun currentTimeMillis(): Long = System.currentTimeMillis()
