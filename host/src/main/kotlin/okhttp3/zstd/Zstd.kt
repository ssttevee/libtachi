package okhttp3.zstd

import dev.tachi.host.NativeZstdInputStream
import okhttp3.CompressionInterceptor
import okio.BufferedSource
import okio.Source
import okio.source

/** Public ABI of OkHttp 5.5.0's Zstd object, backed by bundled libzstd via JNI.
 * zstd-kmp's JVM loader unconditionally extracts a jar resource to a temporary
 * file; the host instead loads only its explicitly bundled native library.
 */
object Zstd : CompressionInterceptor.DecompressionAlgorithm {
    override val encoding: String get() = "zstd"
    override fun decompress(compressedSource: BufferedSource): Source =
        NativeZstdInputStream(compressedSource.inputStream()).source()
}
