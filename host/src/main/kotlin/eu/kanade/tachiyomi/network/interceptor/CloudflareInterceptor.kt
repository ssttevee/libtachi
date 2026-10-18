package eu.kanade.tachiyomi.network.interceptor

import dev.tachi.host.TachiRuntime
import eu.kanade.tachiyomi.network.PersistentCookieJar
import okhttp3.Cookie
import okhttp3.HttpUrl
import okhttp3.Interceptor
import okhttp3.Response
import java.io.IOException
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.locks.ReentrantLock
import kotlin.concurrent.withLock

class CloudflareBypassException(message: String) : IOException(message)

/**
 * Something that can obtain a `cf_clearance` cookie for a URL, e.g. the host
 * application driving a real browser/WebView. Mihon solves challenges with an
 * invisible Android WebView; a headless JVM cannot, so this is delegated.
 */
fun interface CloudflareSolver {
    /** Return cookies (name -> value) to store for [url], or null if the challenge could not be solved. */
    fun solve(url: String, userAgent: String): Map<String, String>?
}

/**
 * Detects Cloudflare challenge pages. If the host registered a [CloudflareSolver],
 * it is invoked and the request retried; otherwise a [CloudflareBypassException]
 * is raised so the caller gets an actionable error instead of an HTML error page.
 */
class CloudflareInterceptor(
    private val cookieJar: PersistentCookieJar,
    private val defaultUserAgentProvider: () -> String,
) : Interceptor {
    private val hostLocks = ConcurrentHashMap<String, ReentrantLock>()

    override fun intercept(chain: Interceptor.Chain): Response {
        val request = chain.request()
        val response = chain.proceed(request)
        if (!isChallenge(response)) return response

        val solver = TachiRuntime.cloudflareSolver
            ?: run {
                response.close()
                throw CloudflareBypassException(
                    "Cloudflare challenge on ${request.url.host}; no CloudflareSolver is registered with the tachi host.",
                )
            }

        val lock = hostLocks.computeIfAbsent(request.url.host) { ReentrantLock() }
        lock.withLock {
            val before = clearance(request.url)
            // Another request may have solved it while we waited on the lock.
            if (clearance(request.url) == before) {
                response.close()
                val cookies = solver.solve(request.url.toString(), defaultUserAgentProvider())
                    ?: throw CloudflareBypassException("Cloudflare challenge on ${request.url.host} could not be solved.")
                cookieJar.addAll(
                    cookies.map { (name, value) ->
                        Cookie.Builder().name(name).value(value).domain(request.url.host).path("/").build()
                    },
                )
            }
        }
        return chain.proceed(request)
    }

    private fun clearance(url: HttpUrl): String? = cookieJar.get(url).firstOrNull { it.name == "cf_clearance" }?.value

    private fun isChallenge(response: Response): Boolean {
        // https://developers.cloudflare.com/cloudflare-challenges/challenge-types/challenge-pages/detect-response/
        if (response.header("cf-mitigated") == "challenge") return true
        return response.code in ERROR_CODES && response.header("Server") in SERVER_CHECK
    }

    companion object {
        private val ERROR_CODES = listOf(403, 503)
        private val SERVER_CHECK = arrayOf("cloudflare-nginx", "cloudflare")
    }
}
