package dev.tachi.host

/**
 * Log sink for everything the host and extensions emit through android.util.Log.
 * When the native side registers [NativeHooks.log] the messages go to the
 * embedding application; otherwise they go to stderr.
 */
object TachiLog {
    const val VERBOSE = 2
    const val DEBUG = 3
    const val INFO = 4
    const val WARN = 5
    const val ERROR = 6
    const val ASSERT = 7

    @Volatile
    var minLevel: Int = INFO

    @Volatile
    var nativeSink: Boolean = false

    @JvmStatic
    fun minLevel(): Int = minLevel

    @JvmStatic
    fun log(level: Int, tag: String, message: String) {
        if (level < minLevel) return
        if (nativeSink) {
            try {
                NativeHooks.log(level, tag.toByteArray(Charsets.UTF_8), message.toByteArray(Charsets.UTF_8))
                return
            } catch (_: UnsatisfiedLinkError) {
                nativeSink = false
            }
        }
        val letter = when (level) {
            VERBOSE -> 'V'
            DEBUG -> 'D'
            INFO -> 'I'
            WARN -> 'W'
            ERROR -> 'E'
            else -> 'A'
        }
        System.err.println("$letter/$tag: $message")
    }

    fun d(tag: String, message: String) = log(DEBUG, tag, message)

    fun i(tag: String, message: String) = log(INFO, tag, message)

    fun w(tag: String, message: String, t: Throwable? = null) =
        log(WARN, tag, if (t != null) message + "\n" + t.stackTraceToString() else message)

    fun e(tag: String, message: String, t: Throwable? = null) =
        log(ERROR, tag, if (t != null) message + "\n" + t.stackTraceToString() else message)
}
