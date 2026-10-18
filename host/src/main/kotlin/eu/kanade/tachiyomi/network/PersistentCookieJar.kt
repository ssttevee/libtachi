package eu.kanade.tachiyomi.network

import kotlinx.serialization.Serializable
import kotlinx.serialization.builtins.ListSerializer
import kotlinx.serialization.json.Json
import okhttp3.Cookie
import okhttp3.CookieJar
import okhttp3.HttpUrl
import okhttp3.HttpUrl.Companion.toHttpUrlOrNull
import java.io.File
import java.util.concurrent.ConcurrentHashMap

/**
 * A simple cookie jar persisted to a JSON file. Stands in for Android's
 * WebView-backed CookieManager, and also backs `android.webkit.CookieManager`
 * so cookies set by extensions through either API are shared.
 */
class PersistentCookieJar(private val file: File?) : CookieJar {
    @Serializable
    private data class StoredCookie(
        val name: String,
        val value: String,
        val domain: String,
        val path: String,
        val expiresAt: Long,
        val secure: Boolean,
        val httpOnly: Boolean,
        val hostOnly: Boolean,
    )

    private val json = Json { ignoreUnknownKeys = true }
    private val store = ConcurrentHashMap<String, MutableMap<String, Cookie>>() // domain -> (name|path -> cookie)

    init {
        load()
    }

    override fun saveFromResponse(url: HttpUrl, cookies: List<Cookie>) {
        addAll(cookies)
    }

    override fun loadForRequest(url: HttpUrl): List<Cookie> {
        val now = System.currentTimeMillis()
        return store.values.asSequence()
            .flatMap { it.values.asSequence() }
            .filter { it.expiresAt > now && it.matches(url) }
            .toList()
    }

    fun get(url: HttpUrl): List<Cookie> = loadForRequest(url)

    fun addAll(cookies: List<Cookie>) {
        if (cookies.isEmpty()) return
        for (cookie in cookies) {
            val bucket = store.getOrPut(cookie.domain) { ConcurrentHashMap() }
            bucket["${cookie.name}|${cookie.path}"] = cookie
        }
        persist()
    }

    /** Parse a `Set-Cookie`-style string for [url], as `android.webkit.CookieManager.setCookie` does. */
    fun setCookie(url: String, cookieString: String) {
        val httpUrl = url.toHttpUrlOrNull() ?: return
        val cookie = Cookie.parse(httpUrl, cookieString) ?: return
        addAll(listOf(cookie))
    }

    fun getCookieHeader(url: String): String? {
        val httpUrl = url.toHttpUrlOrNull() ?: return null
        val cookies = loadForRequest(httpUrl)
        if (cookies.isEmpty()) return null
        return cookies.joinToString("; ") { "${it.name}=${it.value}" }
    }

    fun remove(url: HttpUrl, names: List<String>): Int {
        var removed = 0
        for (bucket in store.values) {
            val it = bucket.entries.iterator()
            while (it.hasNext()) {
                val c = it.next().value
                if (c.name in names && c.matches(url)) {
                    it.remove()
                    removed++
                }
            }
        }
        if (removed > 0) persist()
        return removed
    }

    fun removeAll() {
        store.clear()
        persist()
    }

    fun hasCookies(): Boolean = store.values.any { it.isNotEmpty() }

    @Synchronized
    private fun persist() {
        val f = file ?: return
        try {
            val now = System.currentTimeMillis()
            val list = store.values.flatMap { it.values }
                .filter { it.persistent && it.expiresAt > now }
                .map {
                    StoredCookie(it.name, it.value, it.domain, it.path, it.expiresAt, it.secure, it.httpOnly, it.hostOnly)
                }
            f.parentFile?.mkdirs()
            val tmp = File(f.parentFile, f.name + ".tmp")
            tmp.writeText(json.encodeToString(ListSerializer(StoredCookie.serializer()), list))
            if (!tmp.renameTo(f)) {
                f.delete()
                tmp.renameTo(f)
            }
        } catch (e: Exception) {
            android.util.Log.w("tachi", "Failed to persist cookies", e)
        }
    }

    private fun load() {
        val f = file ?: return
        if (!f.exists()) return
        try {
            val list = json.decodeFromString(ListSerializer(StoredCookie.serializer()), f.readText())
            for (s in list) {
                val builder = Cookie.Builder()
                    .name(s.name)
                    .value(s.value)
                    .path(s.path)
                    .expiresAt(s.expiresAt)
                if (s.hostOnly) builder.hostOnlyDomain(s.domain) else builder.domain(s.domain)
                if (s.secure) builder.secure()
                if (s.httpOnly) builder.httpOnly()
                val cookie = builder.build()
                store.getOrPut(cookie.domain) { ConcurrentHashMap() }["${cookie.name}|${cookie.path}"] = cookie
            }
        } catch (e: Exception) {
            android.util.Log.w("tachi", "Failed to load cookies", e)
        }
    }
}
