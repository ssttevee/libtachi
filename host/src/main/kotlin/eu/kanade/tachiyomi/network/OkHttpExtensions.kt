// Ported from Mihon (Apache-2.0): core/common/src/main/kotlin/eu/kanade/tachiyomi/network/OkHttpExtensions.kt
// The file name matters: extensions link against `eu.kanade.tachiyomi.network.OkHttpExtensionsKt`.
package eu.kanade.tachiyomi.network

import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.serialization.DeserializationStrategy
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.okio.decodeFromBufferedSource
import kotlinx.serialization.serializer
import okhttp3.Call
import okhttp3.Callback
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.Response
import java.io.IOException
import kotlin.coroutines.resumeWithException

val jsonMime = "application/json; charset=utf-8".toMediaType()

// Based on https://github.com/square/okhttp/blob/master/okhttp-coroutines/src/main/kotlin/okhttp3/coroutines/ExecuteAsync.kt
private suspend fun Call.await(callStack: Array<StackTraceElement>): Response {
    dev.tachi.host.Operations.track(this)
    return suspendCancellableCoroutine { continuation ->
        continuation.invokeOnCancellation {
            try {
                this.cancel()
            } catch (_: Throwable) {
                // ignore
            }
        }
        this.enqueue(
            object : Callback {
                override fun onFailure(call: Call, e: IOException) {
                    if (continuation.isCancelled) return
                    val exception = IOException(e.message, e).apply { stackTrace = callStack }
                    continuation.resumeWithException(exception)
                }

                override fun onResponse(call: Call, response: Response) {
                    continuation.resume(response) { _, value, _ -> value.close() }
                }
            },
        )
    }
}

suspend fun Call.await(): Response {
    val callStack = Exception().stackTrace.run { copyOfRange(1, size) }
    return await(callStack)
}

suspend fun Call.awaitSuccess(): Response {
    val callStack = Exception().stackTrace.run { copyOfRange(1, size) }
    val response = await(callStack)
    if (!response.isSuccessful) {
        response.close()
        throw HttpException(response.code).apply { stackTrace = callStack }
    }
    return response
}

fun OkHttpClient.newCachelessCallWithProgress(
    request: Request,
    listener: ProgressListener,
    existingSize: Long = 0L,
): Call {
    val progressClient = newBuilder()
        .cache(null)
        .addNetworkInterceptor { chain ->
            val originalResponse = chain.proceed(chain.request())
            originalResponse.newBuilder()
                .body(ProgressResponseBody(originalResponse.body, listener, existingSize))
                .build()
        }
        .build()
    return progressClient.newCall(request)
}

context(_: Json)
inline fun <reified T> Response.parseAs(): T = decodeFromJsonResponse(serializer(), this)

@OptIn(kotlinx.serialization.ExperimentalSerializationApi::class)
context(json: Json)
fun <T> decodeFromJsonResponse(deserializer: DeserializationStrategy<T>, response: Response): T =
    response.body.source().use { json.decodeFromBufferedSource(deserializer, it) }
