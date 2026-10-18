package eu.kanade.tachiyomi.network

import android.content.Context
import dev.tachi.host.TachiRuntime
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

/**
 * Pluggable JavaScript engine the host application can provide.
 * Mihon backs this with QuickJS; the host runtime has no engine by default.
 */
fun interface JsEngine {
    fun evaluate(script: String): Any?
}

@Suppress("UNUSED", "UNCHECKED_CAST")
class JavaScriptEngine(context: Context) {
    /**
     * Evaluate arbitrary JavaScript code and get the result as a primitive type (e.g., String, Int).
     * @since tachiyomix 1.4
     */
    suspend fun <T> evaluate(script: String): T = withContext(Dispatchers.Default) {
        val engine = TachiRuntime.jsEngine
            ?: throw UnsupportedOperationException(
                "This source needs a JavaScript engine, but none is registered with the tachi host runtime.",
            )
        engine.evaluate(script) as T
    }
}
