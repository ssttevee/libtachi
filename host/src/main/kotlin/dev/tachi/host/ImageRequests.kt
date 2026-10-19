package dev.tachi.host

import eu.kanade.tachiyomi.source.model.SChapter
import eu.kanade.tachiyomi.source.online.HttpSource
import kotlinx.serialization.Serializable
import okhttp3.*
import okio.Buffer
import java.io.IOException
import java.lang.reflect.Field
import java.lang.reflect.Modifier
import java.util.Deque
import java.util.concurrent.Semaphore
import java.util.concurrent.TimeUnit
import java.util.concurrent.locks.Condition
import java.util.concurrent.locks.Lock

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

/** Probe request behavior without opening a connection or executing limiter waits. */
object ImageRequests {
    suspend fun plan(source: HttpSource, chapter: SChapter): List<ImageRequestDto> =
        source.getPageList(chapter).map { page ->
            if (page.imageUrl == null) page.imageUrl = source.getImageUrl(page)
            planRequest(source.client, page.toDto(), source.imageRequestForHost(page))
        }

    // Also used by the offline tests against real extension clients.
    fun planRequest(client: OkHttpClient, page: PageDto, request: Request): ImageRequestDto {
        var finalRequest = request
        var fallback: String? = null
        val rates = mutableListOf<ImageRateDto>()
        val limiters = mutableListOf<Pair<Int, Limiter>>()
        val all = client.interceptors + client.networkInterceptors
        for ((index, interceptor) in all.withIndex()) {
            try {
                val limiter = limiter(interceptor)
                if (limiter != null) {
                    limiters += index to limiter
                } else if (limiterState(interceptor)) {
                    fallback = "unrecognized rate limiter: ${interceptor.javaClass.name}"
                    break
                }
            } catch (e: Throwable) {
                if (e is VirtualMachineError || e is ThreadDeath) throw e
                fallback = "unrecognized rate limiter: ${interceptor.javaClass.name}"
                break
            }
        }
        if (fallback == null) {
            val byIndex = limiters.toMap()
            // Remove the actual waiting implementations. No-wait markers export
            // each rule at its original chain position, before later URL rewrites.
            fun probed(index: Int, interceptor: Interceptor): Interceptor {
                val limiter = byIndex[index] ?: return interceptor
                return Interceptor { chain ->
                    try { rates += limiter.rates(chain.request().url, index) }
                    catch (e: Throwable) {
                        if (e is VirtualMachineError || e is ThreadDeath) throw e
                        throw LimiterProbeException("unrecognized rate limiter: ${interceptor.javaClass.name}", e)
                    }
                    chain.proceed(chain.request())
                }
            }
            val probe = Probe(client, request,
                client.interceptors.mapIndexed { i, interceptor -> probed(i, interceptor) },
                client.networkInterceptors.mapIndexed { i, interceptor -> probed(i + client.interceptors.size, interceptor) })
            try { finalRequest = probe.run() }
            catch (e: Exception) {
                fallback = probe.failure ?: "interceptor probe: ${e.javaClass.simpleName}"
            }
        }
        if (finalRequest.method != "GET" || finalRequest.body != null || request.method != "GET" || request.body != null)
            fallback = "non-GET image request"
        if (client.proxy != null || client.proxyAuthenticator !== Authenticator.NONE ||
            client.authenticator !== Authenticator.NONE || client.certificatePinner.pins.isNotEmpty() || client.dns !== Dns.SYSTEM ||
            client.proxySelector !== TachiRuntime.network.client.proxySelector ||
            client.socketFactory !== TachiRuntime.network.client.socketFactory ||
            client.sslSocketFactory !== TachiRuntime.network.client.sslSocketFactory ||
            client.hostnameVerifier !== TachiRuntime.network.client.hostnameVerifier) {
            fallback = "custom proxy, DNS, authentication or TLS policy"
        }
        if (finalRequest.headers.values("Accept-Encoding").any { !it.equals("identity", ignoreCase = true) })
            fallback = "explicit content encoding"
        val cookies = client.cookieJar.loadForRequest(finalRequest.url)
        return ImageRequestDto(page, finalRequest.url.toString(), finalRequest.method,
            finalRequest.headers.let { h -> (0 until h.size).map { ImageHeaderDto(h.name(it), h.value(it)) } },
            rates, cookies.map { it.toString() }, fallback)
    }

    private fun fields(value: Any): List<Field> = generateSequence(value.javaClass as Class<*>?) { it.superclass }
        .takeWhile { it != Any::class.java }
        .flatMap { it.declaredFields.asSequence() }
        .filterNot { Modifier.isStatic(it.modifiers) || it.isSynthetic }
        .onEach { it.isAccessible = true }.toList()

    private fun timingType(type: Class<*>): Boolean =
        Lock::class.java.isAssignableFrom(type) || Condition::class.java.isAssignableFrom(type) ||
            Semaphore::class.java.isAssignableFrom(type) || Deque::class.java.isAssignableFrom(type) ||
            type.name == "kotlin.collections.ArrayDeque"

    // Inspect the interceptor and its direct rule objects, never execute a suspected
    // limiter. Do not walk captured lambdas or shared client/cookie-jar internals.
    private fun limiterState(value: Any): Boolean = fields(value).any { field ->
        timingType(field.type) || when (val child = field.get(value)) {
            is List<*> -> child.filterNotNull().any { rule ->
                !rule.javaClass.name.startsWith("java.") && fields(rule).any { timingType(it.type) }
            }
            else -> child != null && !child.javaClass.name.startsWith("java.") &&
                !child.javaClass.isPrimitive && !field.type.isPrimitive &&
                !child.javaClass.isSynthetic && fields(child).any { timingType(it.type) }
        }
    }

    private fun durationMillis(raw: Long): Long {
        require(raw >= 0 && raw != Long.MAX_VALUE)
        val value = raw shr 1
        return if (raw and 1L != 0L) value else value / 1_000_000 + if (value % 1_000_000 == 0L) 0 else 1
    }
    private fun exported(index: Int, key: String, permits: Int, period: Long, interval: Long = 0): ImageRateDto {
        require(permits > 0 && period > 0 && period <= Int.MAX_VALUE && interval in 0..Int.MAX_VALUE.toLong())
        return ImageRateDto("$index:$key", maxOf((period + permits - 1) / permits, interval), maxOf(period, interval))
    }
    private fun interface Limiter { fun rates(url: HttpUrl, index: Int): List<ImageRateDto> }

    /** Structural schemas, including inherited fields; no interceptor/field names.
     * Keiyoushi's two Duration longs are declared in period, interval order.
     * Any additional/unknown state rejects the schema and stays on the JVM.
     */
    @Suppress("UNCHECKED_CAST")
    private fun limiter(value: Interceptor): Limiter? {
        val fs = fields(value)
        val lists = fs.filter { List::class.java.isAssignableFrom(it.type) }
        if (fs.size == 1 && lists.size == 1) {
            val rules = lists.single().get(value) as List<*>
            if (rules.isEmpty()) return null // An erased, empty list proves no schema.
            val parsed = rules.map { raw ->
                val rule = requireNotNull(raw)
                val rf = fields(rule)
                val ints = rf.filter { it.type == Int::class.javaPrimitiveType }
                val longs = rf.filter { it.type == Long::class.javaPrimitiveType }
                val predicates = rf.filter { kotlin.jvm.functions.Function1::class.java.isAssignableFrom(it.type) }
                val shape = rf.size == 8 && ints.size == 1 && longs.size == 2 && predicates.size == 1 &&
                    rf.count { Deque::class.java.isAssignableFrom(it.type) } == 1 &&
                    rf.count { Lock::class.java.isAssignableFrom(it.type) } == 1 &&
                    rf.count { Condition::class.java.isAssignableFrom(it.type) } == 1 &&
                    rf.count { it.type == kotlin.time.Duration::class.java } == 1
                if (!shape) return null
                val permits = ints.single().getInt(rule)
                val period = durationMillis(longs[0].getLong(rule))
                val interval = durationMillis(longs[1].getLong(rule))
                exported(0, "validate", permits, period, interval)
                val predicate = predicates.single().get(rule) as (HttpUrl) -> Boolean
                Triple(predicate, permits, period to interval)
            }
            return Limiter { url, index ->
                val i = parsed.indexOfFirst { it.first(url) }
                if (i == -1) emptyList() else parsed[i].let {
                    listOf(exported(index, i.toString(), it.second, it.third.first, it.third.second))
                }
            }
        }
        val hosts = fs.filter { it.type == String::class.java || it.type == HttpUrl::class.java }
        val ints = fs.filter { it.type == Int::class.javaPrimitiveType }
        val longs = fs.filter { it.type == Long::class.javaPrimitiveType }
        if (fs.size == 5 && hosts.size == 1 && ints.size == 1 && longs.size == 1 &&
            fs.count { Deque::class.java.isAssignableFrom(it.type) } == 1 &&
            fs.count { Semaphore::class.java.isAssignableFrom(it.type) } == 1) {
            val host = hosts.single().get(value).let { if (it is HttpUrl) it.host else it as String? }
            val permits = ints.single().getInt(value)
            val period = longs.single().getLong(value)
            exported(0, "validate", permits, period)
            return Limiter { url, index ->
                if (host != null && host != url.host) emptyList() else listOf(exported(index, host ?: "*", permits, period))
            }
        }
        return null
    }

    private class LimiterProbeException(message: String, cause: Throwable) : IOException(message, cause)

    private class Probe(val client: OkHttpClient, val initial: Request,
        application: List<Interceptor>, network: List<Interceptor>) {
        val sentinel = object : ResponseBody() {
            private val buffer = Buffer()
            override fun contentType(): MediaType? = null
            override fun contentLength(): Long = 0
            override fun source() = buffer
        }
        var failure: String? = null
        var captured: Request? = null
        var terminalCalls = 0
        // A real, unexecuted Call supplies tags and timeout state, but every
        // execution entry point (including clone) is guarded against networking.
        fun fakeCall(): Call = object : Call by client.newCall(initial) {
            override fun execute(): Response = throw IOException("probe call cannot execute")
            override fun enqueue(responseCallback: Callback) { throw IOException("probe call cannot enqueue") }
            override fun clone(): Call = fakeCall()
        }
        val call = fakeCall()
        val bridge = Interceptor { chain ->
            val request = chain.request()
            val builder = request.newBuilder()
            if (request.header("User-Agent").isNullOrEmpty()) builder.header("User-Agent", TachiRuntime.config.userAgent)
            val cookies = chain.cookieJar.loadForRequest(request.url)
            if (cookies.isNotEmpty()) builder.header("Cookie", cookies.joinToString("; ") { "${it.name}=${it.value}" })
            builder.header("Accept-Encoding", "identity")
            chain.proceed(builder.build())
        }
        val interceptors = application + bridge + network
        fun run(): Request {
            try {
                Chain(0, initial, client).proceed(initial).use { response ->
                    check(response.body === sentinel && terminalCalls == 1) { "probe did not reach terminal exactly once" }
                }
                return requireNotNull(captured)
            } finally { sentinel.close() }
        }
        inner class Chain(val index: Int, val current: Request, val settings: OkHttpClient) : Interceptor.Chain {
            override fun request(): Request = current
            override fun call(): Call = call
            override fun connection(): Connection? = null
            override fun connectTimeoutMillis() = settings.connectTimeoutMillis
            override fun readTimeoutMillis() = settings.readTimeoutMillis
            override fun writeTimeoutMillis() = settings.writeTimeoutMillis
            override fun withConnectTimeout(timeout: Int, unit: TimeUnit): Interceptor.Chain = Chain(index, current, settings.newBuilder().connectTimeout(timeout.toLong(), unit).build())
            override fun withReadTimeout(timeout: Int, unit: TimeUnit): Interceptor.Chain = Chain(index, current, settings.newBuilder().readTimeout(timeout.toLong(), unit).build())
            override fun withWriteTimeout(timeout: Int, unit: TimeUnit): Interceptor.Chain = Chain(index, current, settings.newBuilder().writeTimeout(timeout.toLong(), unit).build())
            override val followSslRedirects get() = settings.followSslRedirects
            override val followRedirects get() = settings.followRedirects
            override val dns get() = settings.dns
            override val socketFactory get() = settings.socketFactory
            override val retryOnConnectionFailure get() = settings.retryOnConnectionFailure
            override val authenticator get() = settings.authenticator
            override val cookieJar get() = settings.cookieJar
            override val cache get() = settings.cache
            override val proxy get() = settings.proxy
            override val proxySelector get() = settings.proxySelector
            override val proxyAuthenticator get() = settings.proxyAuthenticator
            override val sslSocketFactoryOrNull get() = settings.sslSocketFactory
            override val x509TrustManagerOrNull get() = settings.x509TrustManager
            override val hostnameVerifier get() = settings.hostnameVerifier
            override val certificatePinner get() = settings.certificatePinner
            override val connectionPool get() = settings.connectionPool
            override val eventListener get() = EventListener.NONE
            // A per-call transport override cannot be represented by a native plan.
            private fun unsupported(): Nothing = throw IOException("per-request client policy")
            override fun withDns(dns: Dns): Interceptor.Chain = unsupported()
            override fun withSocketFactory(socketFactory: javax.net.SocketFactory): Interceptor.Chain = unsupported()
            override fun withRetryOnConnectionFailure(retryOnConnectionFailure: Boolean): Interceptor.Chain = unsupported()
            override fun withAuthenticator(authenticator: Authenticator): Interceptor.Chain = unsupported()
            override fun withCookieJar(cookieJar: CookieJar): Interceptor.Chain = unsupported()
            override fun withCache(cache: Cache?): Interceptor.Chain = unsupported()
            override fun withProxy(proxy: java.net.Proxy?): Interceptor.Chain = unsupported()
            override fun withProxySelector(proxySelector: java.net.ProxySelector): Interceptor.Chain = unsupported()
            override fun withProxyAuthenticator(proxyAuthenticator: Authenticator): Interceptor.Chain = unsupported()
            override fun withSslSocketFactory(sslSocketFactory: javax.net.ssl.SSLSocketFactory?, x509TrustManager: javax.net.ssl.X509TrustManager?): Interceptor.Chain = unsupported()
            override fun withHostnameVerifier(hostnameVerifier: javax.net.ssl.HostnameVerifier): Interceptor.Chain = unsupported()
            override fun withCertificatePinner(certificatePinner: CertificatePinner): Interceptor.Chain = unsupported()
            override fun withConnectionPool(connectionPool: ConnectionPool): Interceptor.Chain = unsupported()
            override fun proceed(request: Request): Response {
                if (index == interceptors.size) {
                    terminalCalls++
                    captured = request
                    return Response.Builder().request(request).protocol(Protocol.HTTP_1_1)
                        .code(200).message("Native request probe").body(sentinel).build()
                }
                val interceptor = interceptors[index]
                try {
                    val before = terminalCalls
                    val response = interceptor.intercept(Chain(index + 1, request, settings))
                    if (response.body !== sentinel || terminalCalls - before != 1) {
                        response.close()
                        throw IOException("response body replaced or terminal bypassed/repeated")
                    }
                    return response
                } catch (e: Throwable) {
                    if (e is VirtualMachineError || e is ThreadDeath) throw e
                    if (failure == null) failure = if (e is LimiterProbeException) e.message else
                        "extension interceptor: ${interceptor.javaClass.name}: ${e.message ?: e.javaClass.simpleName}"
                    throw IOException(e)
                }
            }
        }
    }
}
