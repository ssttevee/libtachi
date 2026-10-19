package dev.tachi.host

import eu.kanade.tachiyomi.source.model.Page
import eu.kanade.tachiyomi.source.model.SChapter
import eu.kanade.tachiyomi.source.online.HttpSource
import eu.kanade.tachiyomi.network.interceptor.rateLimitHost
import kotlinx.coroutines.runBlocking
import okhttp3.*
import okhttp3.HttpUrl.Companion.toHttpUrl
import okhttp3.ResponseBody.Companion.toResponseBody
import java.nio.file.Files
import java.io.File
import java.util.concurrent.Semaphore
import java.util.concurrent.TimeUnit

/** Standalone deterministic probe tests; optional jar paths test the installed extensions. */
object ImageRequestsTest {
    private fun plan(client: OkHttpClient, url: String = "https://cdn.example.test/page.png"): ImageRequestDto =
        ImageRequests.planRequest(client, PageDto(0), Request.Builder().url(url).build())
    private fun native(result: ImageRequestDto): ImageRequestDto {
        check(result.fallback == null) { result.toString() }
        return result
    }
    private fun fallback(result: ImageRequestDto, text: String) {
        check(result.fallback?.contains(text) == true) { result.toString() }
    }
    private class BodyTransform : Interceptor {
        override fun intercept(chain: Interceptor.Chain): Response =
            chain.proceed(chain.request()).let {
                if (chain.request().url.encodedPath.contains("scrambled")) it.newBuilder().body("decoded".toResponseBody()).build() else it
            }
    }
    private class Throwing : Interceptor {
        override fun intercept(chain: Interceptor.Chain): Response = throw IllegalStateException("probe test")
    }
    private class AssertionThrowing : Interceptor {
        override fun intercept(chain: Interceptor.Chain): Response = throw AssertionError("probe assertion")
    }
    private class UnknownLimiter : Interceptor {
        private val semaphore = Semaphore(1)
        override fun intercept(chain: Interceptor.Chain): Response = error("limiter must not execute")
    }
    private class UnknownRuleLimiter : Interceptor {
        private class Rule { val deque = java.util.ArrayDeque<Long>() }
        private val rules = listOf(Rule())
        override fun intercept(chain: Interceptor.Chain): Response = error("rule limiter must not execute")
    }
    // Minified schema, with absurdly large waits: running this interceptor is a failure.
    private class MinifiedLimiter : Interceptor {
        private class Rule(val a: Int, val b: Long, val c: Long, val d: (HttpUrl) -> Boolean) {
            val e = java.util.ArrayDeque<kotlin.time.Duration>()
            val f = java.util.concurrent.locks.ReentrantLock()
            val g = f.newCondition()
            var h: kotlin.time.Duration? = null
        }
        private val a = listOf(
            Rule(3, 10_000_000_000L, 4_000_000_000L) { it.host == "cdn.example.test" },
            Rule(2, 6_000_000_000L, 0L) { true },
        )
        override fun intercept(chain: Interceptor.Chain): Response = error("recognized limiter must not execute")
    }
    @JvmStatic fun main(args: Array<String>) {
        TachiRuntime.init(RuntimeConfig(dataDir = Files.createTempDirectory("tachi-plan-").toString()))
        val base = TachiRuntime.network.client
        native(plan(base))
        val jar = object : CookieJar {
            override fun saveFromResponse(url: HttpUrl, cookies: List<Cookie>) {}
            override fun loadForRequest(url: HttpUrl): List<Cookie> =
                listOf(Cookie.Builder().name("session").value(url.host).hostOnlyDomain(url.host).build())
        }
        val changed = base.newBuilder().cookieJar(jar)
            .addInterceptor { chain ->
                check(chain.connection() == null && !chain.call().isCanceled())
                check(chain.connectTimeoutMillis() > 0 && chain.readTimeoutMillis() > 0 && chain.writeTimeoutMillis() > 0)
                chain.withReadTimeout(2, TimeUnit.SECONDS).proceed(chain.request().newBuilder()
                    .url("https://final.example.test/final.png").header("User-Agent", "probe-agent")
                    .header("Accept-Encoding", "gzip").build())
            }
            .addNetworkInterceptor { chain ->
                check(chain.request().header("Accept-Encoding") == "identity")
                check(chain.request().header("Cookie") == "session=final.example.test")
                chain.proceed(chain.request().newBuilder().addHeader("Cookie", "injected=yes")
                    .header("X-Signature", chain.request().url.encodedPath).build())
                    .newBuilder().header("Cache-Control", "max-age=60").build()
            }.build()
        val result = native(plan(changed))
        check(result.url == "https://final.example.test/final.png")
        check(result.headers.any { it.name == "User-Agent" && it.value == "probe-agent" })
        check(result.headers.any { it.name == "Cookie" && it.value == "injected=yes" })
        check(result.headers.any { it.name == "X-Signature" && it.value == "/final.png" })
        val transform = base.newBuilder().addNetworkInterceptor(BodyTransform()).build()
        native(plan(transform))
        fallback(plan(transform, "https://cdn.example.test/scrambled.png"), "BodyTransform")
        fallback(plan(base.newBuilder().addInterceptor(Throwing()).build()), "Throwing")
        fallback(plan(base.newBuilder().addInterceptor(AssertionThrowing()).build()), "AssertionThrowing")
        fallback(plan(base.newBuilder().addInterceptor(UnknownLimiter()).build()), "unrecognized rate limiter")
        fallback(plan(base.newBuilder().addInterceptor(UnknownRuleLimiter()).build()), "unrecognized rate limiter")
        val limited = base.newBuilder().addInterceptor(MinifiedLimiter()).build()
        check(native(plan(limited)).rates.single().let { it.spacingMs == 2000L && it.initialWaitMs == 5000L })
        check(native(plan(limited, "https://other.example.test/page.png")).rates.single().spacingMs == 1500L)
        val legacy = base.newBuilder().rateLimitHost("https://cdn.example.test".toHttpUrl(), 2, 1, TimeUnit.SECONDS).build()
        check(native(plan(legacy)).rates.single().spacingMs == 500L)
        check(native(plan(legacy, "https://other.example.test/page.png")).rates.isEmpty())
        val rewrittenLimit = legacy.newBuilder().addInterceptor { chain ->
            chain.proceed(chain.request().newBuilder().url("https://other.example.test/page.png").build())
        }.addNetworkInterceptor(MinifiedLimiter()).build()
        val rewrittenRates = native(plan(rewrittenLimit)).rates
        check(rewrittenRates.size == 2 && rewrittenRates[0].spacingMs == 500L && rewrittenRates[1].spacingMs == 1500L)

        fallback(plan(base.newBuilder().addNetworkInterceptor { chain ->
            chain.proceed(chain.request().newBuilder().header("Accept-Encoding", "br").build())
        }.build()), "explicit content encoding")
        fallback(plan(base.newBuilder().addNetworkInterceptor { chain ->
            chain.proceed(chain.request().newBuilder().post(okhttp3.RequestBody.create(null, "body")).build())
        }.build()), "non-GET")
        fallback(plan(base.newBuilder().addInterceptor { chain ->
            Response.Builder().request(chain.request()).protocol(Protocol.HTTP_1_1).code(200).message("shortcut").body("".toResponseBody()).build()
        }.build()), "extension interceptor")
        fallback(plan(base.newBuilder().addInterceptor { chain ->
            chain.proceed(chain.request()).close()
            chain.proceed(chain.request())
        }.build()), "extension interceptor")
        fallback(plan(base.newBuilder().addInterceptor { chain ->
            chain.call().clone().execute()
        }.build()), "extension interceptor")
        println("PASS: probe URL/headers/cookies, application/bridge/network ordering, body transforms, exceptions, bypass/retry, no-network Call, structural and legacy limits")
        for (path in args.filter { it != "--live" }) {
            val info = ExtensionLoader.install(File(path))
            val source = ExtensionLoader.source(info.sources.firstOrNull { it.id == "2499283573021220255" }?.id?.toLong()
                ?: info.sources.first().id.toLong()) as HttpSource
            val dex = info.pkg.contains("mangadex")
            val url = if (dex) "https://node.mangadex.network/token/data/hash/file.jpg" else "https://zjcdn.mangahere.org/store/manga/1/001.jpg"
            val page = if (dex) Page(0,
                "https://node.mangadex.network/token,https://api.mangadex.org/at-home/server/test,${System.currentTimeMillis()}",
                "/data/hash/file.jpg") else Page(0, "", url)
            val request = source.imageRequestForHost(page)
            val planned = native(ImageRequests.planRequest(source.client, PageDto(0), request))
            println("${info.name} ${info.versionName} ${source.lang}: ${source.client.interceptors.map { it.javaClass.name }} network=${source.client.networkInterceptors.map { it.javaClass.name }}")
            println("  url=${planned.url} rates=${planned.rates} headers=${planned.headers}")
            check(planned.url == url)
            check(planned.rates.isNotEmpty())
            if (dex) check(planned.rates.single().let { it.spacingMs == 334L && it.initialWaitMs == 1000L })
            if (!dex) {
                check(planned.rates.single().let { it.spacingMs == 1000L && it.initialWaitMs == 1000L })
                for (host in listOf("fanfox.net", "m.fanfox.net")) {
                    val cookiePlan = native(ImageRequests.planRequest(source.client, PageDto(0),
                        source.imageRequestForHost(Page(0, "", "https://$host/page.jpg"))))
                    val cookie = cookiePlan.headers.filter { it.name.equals("Cookie", true) }.joinToString("; ") { it.value }
                    check("isAdult=1" in cookie)
                    if (host.startsWith("m.")) check("readway=2" in cookie)
                }
                println("PASS: MangaFox dynamic main/mobile domain cookies")
            }
            if (dex && "--live" in args) {
                val chapter = SChapter.create().apply { this.url = "/chapter/4d384eeb-0aad-4463-9b17-62b45f4fcbda" }
                val pages = runBlocking { ImageRequests.plan(source, chapter) }
                check(pages.isNotEmpty() && pages.all { it.fallback == null }) { pages.toString() }
                println("PASS: live MangaDex chapter ${pages.size} native requests; rates=${pages.first().rates}")
            }
            println("PASS: installed ${info.name} ${info.versionName} client produces native plan")
        }
    }
}
