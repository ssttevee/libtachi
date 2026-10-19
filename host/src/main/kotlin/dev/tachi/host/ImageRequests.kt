package dev.tachi.host

import eu.kanade.tachiyomi.source.model.SChapter
import eu.kanade.tachiyomi.source.online.HttpSource
import kotlinx.serialization.Serializable
import okhttp3.HttpUrl
import okhttp3.Interceptor

@Serializable
data class ImageHeaderDto(val name: String, val value: String)
@Serializable
data class ImageRateDto(val key: String, val spacingMs: Long, val initialWaitMs: Long)
@Serializable
data class ImageRequestDto(
    val page: PageDto,
    val url: String,
    val method: String,
    val headers: List<ImageHeaderDto>,
    val rates: List<ImageRateDto>,
    val cookies: List<String>,
    val fallback: String? = null,
)

/** Unknown extension interceptors always remain on their original client. */
object ImageRequests {
    private val safe = setOf(
        "eu.kanade.tachiyomi.network.interceptor.UncaughtExceptionInterceptor",
        "eu.kanade.tachiyomi.network.interceptor.UserAgentInterceptor",
        "eu.kanade.tachiyomi.network.interceptor.CloudflareInterceptor",
        "okhttp3.logging.HttpLoggingInterceptor",
        "okhttp3.brotli.BrotliInterceptor",
        "okhttp3.CompressionInterceptor",
        "keiyoushi.network.RateLimitInterceptor\$TaggingInterceptor",
    )

    suspend fun plan(source: HttpSource, chapter: SChapter): List<ImageRequestDto> {
        val client = source.client
        return source.getPageList(chapter).map { page ->
            if (page.imageUrl == null) page.imageUrl = source.getImageUrl(page)
            val request = source.imageRequestForHost(page)
            var fallback: String? = if (request.method != "GET" || request.body != null) "non-GET image request" else null
            val rates = mutableListOf<ImageRateDto>()
            val injectedCookies = mutableListOf<Pair<String, String>>()
            for ((index, interceptor) in (client.interceptors + client.networkInterceptors).withIndex()) {
                val name = interceptor.javaClass.name
                if (name.endsWith(".RateLimitInterceptor")) {
                    try { rates += rate(interceptor, request.url, index) }
                    catch (_: Exception) { fallback = "unrecognized rate limiter: $name" }
                } else if (name == "keiyoushi.network.CookieInterceptor") {
                    try { injectedCookies += cookieOverrides(interceptor, request.url) }
                    catch (_: Exception) { fallback = "unrecognized cookie interceptor: $name" }
                } else if (name !in safe) {
                    fallback = "extension interceptor: $name"
                }
            }
            if (client.proxy != null || client.proxyAuthenticator !== okhttp3.Authenticator.NONE ||
                client.authenticator !== okhttp3.Authenticator.NONE || client.certificatePinner.pins.isNotEmpty() || client.dns !== okhttp3.Dns.SYSTEM ||
                client.sslSocketFactory !== TachiRuntime.network.client.sslSocketFactory ||
                client.hostnameVerifier !== TachiRuntime.network.client.hostnameVerifier) {
                fallback = "custom proxy, DNS, authentication or TLS policy"
            }
            val headers = request.headers.newBuilder()
            if (request.header("User-Agent").isNullOrEmpty()) headers.set("User-Agent", TachiRuntime.config.userAgent)
            // Match OkHttp BridgeInterceptor: a non-empty jar replaces Cookie.
            val cookies = client.cookieJar.loadForRequest(request.url)
            if (cookies.isNotEmpty()) headers.set("Cookie", cookies.joinToString("; ") { "${it.name}=${it.value}" })
            if (injectedCookies.isNotEmpty()) {
                val original = headers.get("Cookie")?.split("; ") ?: emptyList()
                headers.set("Cookie", (original.filterNot { cookie -> injectedCookies.any { cookie.startsWith("${it.first}=") } } +
                    injectedCookies.map { "${it.first}=${it.second}" }).joinToString("; "))
            }
            // Zig asks for identity; extension-specific encodings need their client.
            if (request.header("Accept-Encoding")?.let { it != "identity" } == true) fallback = "explicit content encoding"
            headers.set("Accept-Encoding", "identity")
            ImageRequestDto(page.toDto(), request.url.toString(), request.method,
                headers.build().let { h -> (0 until h.size).map { ImageHeaderDto(h.name(it), h.value(it)) } }, rates, cookies.map { it.toString() }, fallback)
        }
    }

    private fun field(value: Any, name: String): Any? = value.javaClass.getDeclaredField(name).let {
        it.isAccessible = true
        it.get(value)
    }

    @Suppress("UNCHECKED_CAST")
    private fun cookieOverrides(value: Interceptor, url: HttpUrl): List<Pair<String, String>> {
        val configs = field(value, "configs") as List<*>
        for (raw in configs) {
            val config = requireNotNull(raw)
            val domain = (field(config, "domain") as () -> String)()
            if (url.host != domain && !url.host.endsWith(".$domain")) continue
            val cookies = (field(config, "cookies") as () -> List<Pair<String, String>>)()
            for ((name, content) in cookies) okhttp3.Cookie.Builder().name(name).value(content).domain(domain).build()
            return cookies
        }
        return emptyList()
    }

    // Kotlin Duration stores nanoseconds shifted left one, or milliseconds with low bit 1.
    private fun durationMillis(raw: Long): Long = if (raw and 1L != 0L) raw shr 1 else ((raw shr 1) + 999999L) / 1000000L

    @Suppress("UNCHECKED_CAST")
    private fun rate(value: Interceptor, url: HttpUrl, index: Int): List<ImageRateDto> {
        if (value.javaClass.name == "eu.kanade.tachiyomi.network.interceptor.RateLimitInterceptor") {
            val host = field(value, "host") as String?
            if (host != null && host != url.host) return emptyList()
            val permits = field(value, "permits") as Int
            val period = field(value, "rateLimitMillis") as Long
            require(permits > 0 && period > 0 && period <= Int.MAX_VALUE)
            return listOf(ImageRateDto("$index:${host ?: "*"}", (period + permits - 1) / permits, period))
        }
        require(value.javaClass.name == "keiyoushi.network.RateLimitInterceptor")
        val rules = field(value, "rateLimits") as List<*>
        for ((ruleIndex, raw) in rules.withIndex()) {
            val rule = requireNotNull(raw)
            val predicate = field(rule, "shouldLimit") as (HttpUrl) -> Boolean
            if (!predicate(url)) continue
            val permits = field(rule, "permits") as Int
            val period = durationMillis(field(rule, "period") as Long)
            val interval = durationMillis(field(rule, "interval") as Long)
            require(permits > 0 && period > 0 && period <= Int.MAX_VALUE && interval >= 0 && interval <= Int.MAX_VALUE)
            return listOf(ImageRateDto("$index:$ruleIndex", maxOf((period + permits - 1) / permits, interval), maxOf(period, interval)))
        }
        return emptyList()
    }
}
