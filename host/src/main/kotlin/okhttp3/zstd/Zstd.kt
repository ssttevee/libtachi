package okhttp3.zstd

import io.airlift.compress.zstd.ZstdInputStream
import okhttp3.CompressionInterceptor
import okio.BufferedSource
import okio.Source
import okio.source

/**
 * Binary-compatible replacement for okhttp-zstd 5.5.0's Kotlin object.
 * Extensions link directly to INSTANCE; dropping that artifact alone breaks them.
 * Aircompressor 0.27 needs no JNI or FFM. Its word accesses are rewritten at
 * build time through AlignedUnsafe for strict-alignment ARM Zero.
 */
object Zstd : CompressionInterceptor.DecompressionAlgorithm {
    override val encoding: String get() = "zstd"

    override fun decompress(compressedSource: BufferedSource): Source =
        ZstdInputStream(compressedSource.inputStream()).source()
}
