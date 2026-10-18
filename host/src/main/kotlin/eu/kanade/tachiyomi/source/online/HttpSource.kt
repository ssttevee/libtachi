// Adapted from Mihon (Apache-2.0) for extensions-lib 1.6: no RxJava, no deprecated request/parse helpers.
package eu.kanade.tachiyomi.source.online

import eu.kanade.tachiyomi.network.GET
import eu.kanade.tachiyomi.network.NetworkHelper
import eu.kanade.tachiyomi.network.awaitSuccess
import eu.kanade.tachiyomi.network.newCachelessCallWithProgress
import eu.kanade.tachiyomi.source.CatalogueSource
import eu.kanade.tachiyomi.source.model.Page
import eu.kanade.tachiyomi.source.model.SChapter
import eu.kanade.tachiyomi.source.model.SManga
import okhttp3.Headers
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.Response
import uy.kohesive.injekt.injectLazy
import java.net.URI
import java.net.URISyntaxException
import java.security.MessageDigest

/** A simple implementation for sources from a website. */
@Suppress("unused")
abstract class HttpSource : CatalogueSource {
    /** Network service. */
    protected val network: NetworkHelper by injectLazy()

    /** Base url of the website without the trailing slash, like: https://example.com */
    abstract val baseUrl: String

    open fun getHomeUrl(): String = baseUrl

    /** Version id used to generate the source id. Increment only if the source id must change. */
    open val versionId: Int = 1

    /** ID of the source. By default it's derived from name, lang and versionId. */
    override val id: Long by lazy { generateId(name, lang, versionId) }

    /** Headers used for requests. */
    val headers: Headers by lazy { headersBuilder().build() }

    /** Default network client for doing requests. */
    open val client: OkHttpClient
        get() = network.client

    @Suppress("MemberVisibilityCanBePrivate")
    protected fun generateId(name: String, lang: String, versionId: Int): Long {
        val key = "${name.lowercase()}/$lang/$versionId"
        val bytes = MessageDigest.getInstance("MD5").digest(key.toByteArray())
        return (0..7).map { bytes[it].toLong() and 0xff shl 8 * (7 - it) }.reduce(Long::or) and Long.MAX_VALUE
    }

    /** Headers builder for requests. Implementations can override this method for custom headers. */
    protected open fun headersBuilder(): Headers.Builder = Headers.Builder().apply {
        add("User-Agent", network.defaultUserAgentProvider())
    }

    override fun toString(): String = "$name (${lang.uppercase()})"

    /**
     * Returns the url of the image for a page when it was not already present in [Page.imageUrl].
     * Sources that provide page lists without image urls must override this.
     */
    open suspend fun getImageUrl(page: Page): String =
        page.imageUrl ?: throw UnsupportedOperationException("$name does not implement getImageUrl")

    /** Downloads the image bytes of a page through the source's client, reporting progress on [page]. */
    suspend fun getImage(page: Page, existingSize: Long = 0L): Response =
        client.newCachelessCallWithProgress(imageRequest(page), page, existingSize).awaitSuccess()

    /** Returns the request for getting the image. Override to send different headers or request method. */
    protected open fun imageRequest(page: Page): Request = GET(page.imageUrl!!, headers)

    /** Assigns the url of the chapter without the scheme and domain. */
    fun SChapter.setUrlWithoutDomain(url: String) {
        this.url = getUrlWithoutDomain(url)
    }

    /** Assigns the url of the manga without the scheme and domain. */
    fun SManga.setUrlWithoutDomain(url: String) {
        this.url = getUrlWithoutDomain(url)
    }

    private fun getUrlWithoutDomain(orig: String): String {
        return try {
            val uri = URI(orig.replace(" ", "%20"))
            var out = uri.path
            if (uri.query != null) out += "?" + uri.query
            if (uri.fragment != null) out += "#" + uri.fragment
            out
        } catch (_: URISyntaxException) {
            orig
        }
    }

    /** Returns the url of the provided manga, suitable for opening in a browser. */
    abstract fun getMangaUrl(manga: SManga): String

    /** Returns the url of the provided chapter, suitable for opening in a browser. */
    abstract fun getChapterUrl(chapter: SChapter): String
}
