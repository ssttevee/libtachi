package dev.tachi.host

/**
 * Callbacks from the JVM into the native host. The native side registers these
 * with `RegisterNatives`; nothing here is called unless it did.
 * Strings cross the boundary as UTF-8 byte arrays to avoid JNI's modified UTF-8.
 */
object NativeHooks {
    @JvmStatic
    external fun log(level: Int, tag: ByteArray, message: ByteArray)
}
