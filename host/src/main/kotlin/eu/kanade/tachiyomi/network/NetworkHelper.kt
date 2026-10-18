// Adapted from Mihon (Apache-2.0): core/common/src/main/kotlin/eu/kanade/tachiyomi/network/NetworkHelper.kt
package eu.kanade.tachiyomi.network

import android.content.Context
import dev.tachi.host.TachiRuntime
import eu.kanade.tachiyomi.network.interceptor.CloudflareInterceptor
import eu.kanade.tachiyomi.network.interceptor.UncaughtExceptionInterceptor
import eu.kanade.tachiyomi.network.interceptor.UserAgentInterceptor
import okhttp3.Cache
import okhttp3.OkHttpClient
import okhttp3.logging.HttpLoggingInterceptor
import java.io.File
import java.util.concurrent.TimeUnit

class NetworkHelper(context: Context) {
    val cookieJar = PersistentCookieJar(File(context.filesDir, "cookies.json"))

    private val cacheDir = File(context.cacheDir, "network_cache")
    private val cacheSize = 5L * 1024 * 1024 // 5 MiB

    private fun clientBuilder(): OkHttpClient.Builder {
        val builder = OkHttpClient.Builder()
            .cookieJar(cookieJar)
            .connectTimeout(30, TimeUnit.SECONDS)
            .readTimeout(30, TimeUnit.SECONDS)
            .callTimeout(2, TimeUnit.MINUTES)
            .cache(Cache(cacheDir, cacheSize))
            .addInterceptor(UncaughtExceptionInterceptor())
            .addInterceptor(UserAgentInterceptor(::defaultUserAgentProvider))

        if (TachiRuntime.config.verbose) {
            val logging = HttpLoggingInterceptor { message -> android.util.Log.d("okhttp", message) }
            logging.level = HttpLoggingInterceptor.Level.HEADERS
            builder.addNetworkInterceptor(logging)
        }
        return builder
    }

    val client: OkHttpClient by lazy {
        clientBuilder()
            .addInterceptor(CloudflareInterceptor(cookieJar, ::defaultUserAgentProvider))
            .build()
    }

    @Deprecated("The regular client handles Cloudflare by default")
    @Suppress("UNUSED")
    val cloudflareClient: OkHttpClient
        get() = client

    fun defaultUserAgentProvider(): String = TachiRuntime.config.userAgent
}
