package app.runsolo.core.platform

import java.io.ByteArrayOutputStream
import java.util.zip.GZIPInputStream
import java.util.zip.GZIPOutputStream

actual fun gzip(bytes: ByteArray): ByteArray {
    val out = ByteArrayOutputStream()
    GZIPOutputStream(out).use { it.write(bytes) }
    return out.toByteArray()
}

actual fun gunzip(bytes: ByteArray): ByteArray = GZIPInputStream(bytes.inputStream()).readBytes()

actual typealias IOException = java.io.IOException

actual typealias FileNotFoundException = java.io.FileNotFoundException

actual fun formatDouble(d: Double): String = d.toString()

actual fun currentTimeMillis(): Long = System.currentTimeMillis()
