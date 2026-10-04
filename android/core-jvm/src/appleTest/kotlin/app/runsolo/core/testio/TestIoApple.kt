@file:OptIn(ExperimentalForeignApi::class)

package app.runsolo.core.testio

import kotlinx.cinterop.ExperimentalForeignApi
import kotlinx.cinterop.addressOf
import kotlinx.cinterop.convert
import kotlinx.cinterop.pointed
import kotlinx.cinterop.toKString
import kotlinx.cinterop.usePinned
import platform.posix.F_OK
import platform.posix.SEEK_END
import platform.posix.SEEK_SET
import platform.posix.access
import platform.posix.closedir
import platform.posix.fclose
import platform.posix.fopen
import platform.posix.fread
import platform.posix.fseek
import platform.posix.ftell
import platform.posix.fwrite
import platform.posix.mkdir
import platform.posix.opendir
import platform.posix.readdir

actual fun testFileExists(abs: String) = access(abs, F_OK) == 0

actual fun testReadBytes(abs: String): ByteArray {
    val f = fopen(abs, "rb") ?: error("cannot open $abs")
    try {
        fseek(f, 0, SEEK_END)
        val n = ftell(f).toInt()
        fseek(f, 0, SEEK_SET)
        val buf = ByteArray(n)
        if (n > 0) buf.usePinned { fread(it.addressOf(0), 1u, n.convert(), f) }
        return buf
    } finally {
        fclose(f)
    }
}

actual fun testWriteBytes(abs: String, bytes: ByteArray) {
    val f = fopen(abs, "wb") ?: error("cannot open $abs")
    try {
        if (bytes.isNotEmpty()) bytes.usePinned { fwrite(it.addressOf(0), 1u, bytes.size.convert(), f) }
    } finally {
        fclose(f)
    }
}

actual fun testMkdirs(abs: String): Boolean {
    var p = ""
    for (part in abs.split('/').filter { it.isNotEmpty() }) {
        p += "/$part"
        mkdir(p, 0x1ed.convert()) // 0755; EEXIST ignored
    }
    return testFileExists(abs)
}

actual fun testList(abs: String): List<String>? {
    val d = opendir(abs) ?: return null
    try {
        val out = ArrayList<String>()
        while (true) {
            val e = readdir(d) ?: break
            val n = e.pointed.d_name.toKString()
            if (n != "." && n != "..") out.add(n)
        }
        return out
    } finally {
        closedir(d)
    }
}

actual class JavaRandom actual constructor(seed: Long) {
    private var seed = (seed xor 0x5DEECE66DL) and ((1L shl 48) - 1)
    private var nextNextGaussian = 0.0
    private var haveNextNextGaussian = false

    private fun next(bits: Int): Int {
        seed = (seed * 0x5DEECE66DL + 0xBL) and ((1L shl 48) - 1)
        return (seed ushr (48 - bits)).toInt()
    }

    private fun nextDouble(): Double = ((next(26).toLong() shl 27) + next(27)) * (1.0 / (1L shl 53))

    actual fun nextGaussian(): Double {
        if (haveNextNextGaussian) {
            haveNextNextGaussian = false
            return nextNextGaussian
        }
        var v1: Double
        var v2: Double
        var s: Double
        do {
            v1 = 2 * nextDouble() - 1
            v2 = 2 * nextDouble() - 1
            s = v1 * v1 + v2 * v2
        } while (s >= 1 || s == 0.0)
        val multiplier = kotlin.math.sqrt(-2 * kotlin.math.ln(s) / s)
        nextNextGaussian = v2 * multiplier
        haveNextNextGaussian = true
        return v1 * multiplier
    }
}
