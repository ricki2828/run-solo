@file:OptIn(ExperimentalForeignApi::class)

package app.runsolo.core.platform

import kotlinx.cinterop.ExperimentalForeignApi
import kotlinx.cinterop.addressOf
import kotlinx.cinterop.alloc
import kotlinx.cinterop.convert
import kotlinx.cinterop.memScoped
import kotlinx.cinterop.ptr
import kotlinx.cinterop.reinterpret
import kotlinx.cinterop.sizeOf
import kotlinx.cinterop.usePinned
import platform.posix.memset
import platform.zlib.Z_BUF_ERROR
import platform.zlib.Z_DEFAULT_COMPRESSION
import platform.zlib.Z_DEFAULT_STRATEGY
import platform.zlib.Z_DEFLATED
import platform.zlib.Z_FINISH
import platform.zlib.Z_NO_FLUSH
import platform.zlib.Z_OK
import platform.zlib.Z_STREAM_END
import platform.zlib.ZLIB_VERSION
import platform.zlib.deflate
import platform.zlib.deflateBound
import platform.zlib.deflateEnd
import platform.zlib.deflateInit2_
import platform.zlib.inflate
import platform.zlib.inflateEnd
import platform.zlib.inflateInit2_
import platform.zlib.z_stream

// windowBits 15 + 16 = gzip wrapper (what GZIPOutputStream writes); + 32 on inflate = auto-detect.
actual fun gzip(bytes: ByteArray): ByteArray = memScoped {
    val strm = alloc<z_stream>()
    memset(strm.ptr, 0, sizeOf<z_stream>().convert())
    val rc = deflateInit2_(strm.ptr, Z_DEFAULT_COMPRESSION, Z_DEFLATED, 15 + 16, 8, Z_DEFAULT_STRATEGY, ZLIB_VERSION, sizeOf<z_stream>().convert())
    if (rc != Z_OK) throw IOException("deflateInit2 $rc")
    try {
        val cap = deflateBound(strm.ptr, bytes.size.convert()).toInt() + 32
        val out = ByteArray(cap)
        val input = if (bytes.isEmpty()) ByteArray(1) else bytes
        input.usePinned { i ->
            out.usePinned { o ->
                strm.next_in = i.addressOf(0).reinterpret()
                strm.avail_in = bytes.size.convert()
                strm.next_out = o.addressOf(0).reinterpret()
                strm.avail_out = cap.convert()
                val r = deflate(strm.ptr, Z_FINISH)
                if (r != Z_STREAM_END) throw IOException("deflate $r")
            }
        }
        out.copyOf(strm.total_out.toInt())
    } finally {
        deflateEnd(strm.ptr)
    }
}

actual fun gunzip(bytes: ByteArray): ByteArray = memScoped {
    val strm = alloc<z_stream>()
    memset(strm.ptr, 0, sizeOf<z_stream>().convert())
    val rc = inflateInit2_(strm.ptr, 15 + 32, ZLIB_VERSION, sizeOf<z_stream>().convert())
    if (rc != Z_OK) throw IOException("inflateInit2 $rc")
    try {
        var out = ByteArray(maxOf(256, bytes.size * 8))
        val input = if (bytes.isEmpty()) ByteArray(1) else bytes
        input.usePinned { i ->
            strm.next_in = i.addressOf(0).reinterpret()
            strm.avail_in = bytes.size.convert()
            while (true) {
                val done = strm.total_out.toInt()
                if (done == out.size) out = out.copyOf(out.size * 2)
                val r = out.usePinned { o ->
                    strm.next_out = o.addressOf(done).reinterpret()
                    strm.avail_out = (out.size - done).convert()
                    inflate(strm.ptr, Z_NO_FLUSH)
                }
                if (r == Z_STREAM_END) break
                if (r != Z_OK && r != Z_BUF_ERROR) throw IOException("inflate $r")
                if (r == Z_BUF_ERROR && strm.avail_in == 0u) throw IOException("truncated gzip")
            }
        }
        out.copyOf(strm.total_out.toInt())
    } finally {
        inflateEnd(strm.ptr)
    }
}

actual open class IOException actual constructor(message: String?) : Exception(message)

actual class FileNotFoundException actual constructor(message: String?) : IOException(message)

/** Spike: Kotlin/Native's own Double.toString; DoubleFormatProbeTest measures how it differs from the JVM. */
actual fun formatDouble(d: Double): String = d.toString()

actual fun currentTimeMillis(): Long = (platform.Foundation.NSDate().timeIntervalSince1970 * 1000.0).toLong()
