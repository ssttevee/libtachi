package dev.tachi.host

import eu.kanade.tachiyomi.source.Source
import eu.kanade.tachiyomi.source.model.FilterList
import eu.kanade.tachiyomi.source.model.MangasPage
import eu.kanade.tachiyomi.source.model.Page
import eu.kanade.tachiyomi.source.model.SChapter
import eu.kanade.tachiyomi.source.model.SManga
import eu.kanade.tachiyomi.source.model.SMangaUpdate
import eu.kanade.tachiyomi.source.online.HttpSource
import java.io.IOException
import java.util.concurrent.ConcurrentHashMap
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.awaitCancellation
import okhttp3.Headers
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Protocol
import okhttp3.Response
import okhttp3.ResponseBody.Companion.toResponseBody

/** Loaded only by the opt-in native JNI integration test. */
object CancellationFixture {
    private val started = ConcurrentHashMap.newKeySet<Long>()
    private val ended = ConcurrentHashMap.newKeySet<Long>()
    private val release = CompletableDeferred<Unit>()

    private open class FixtureSource(override val id: Long) : Source {
        override val name = "Cancellation fixture"
        override val lang = "en"
        override val supportsLatest = false
        override fun getFilterList() = FilterList()
        override suspend fun getPopularManga(page: Int): MangasPage {
            started.add(id)
            try {
                when (id) {
                    101L -> awaitCancellation()
                    102L -> release.await()
                    103L -> throw IOException("fixture diagnostic")
                }
                return MangasPage(emptyList(), false)
            } finally { ended.add(id) }
        }
        override suspend fun getLatestUpdates(page: Int) = error("unused")
        override suspend fun getSearchManga(page: Int, query: String, filters: FilterList) = error("unused")
        override suspend fun getMangaUpdate(manga: SManga, chapters: List<SChapter>, fetchDetails: Boolean, fetchChapters: Boolean): SMangaUpdate = error("unused")
        override suspend fun getPageList(chapter: SChapter): List<Page> = error("unused")
    }

    private val imageClient = OkHttpClient.Builder().addInterceptor { chain ->
        Response.Builder().request(chain.request()).protocol(Protocol.HTTP_1_1).code(200).message("OK")
            .body("fixture image".toByteArray().toResponseBody("image/png".toMediaType())).build()
    }.build()

    @JvmStatic fun cleanup() {
        release.complete(Unit)
        imageClient.dispatcher.executorService.shutdownNow()
        imageClient.connectionPool.evictAll()
    }

    @JvmStatic fun install() {
        val field = ExtensionLoader::class.java.getDeclaredField("sourcesById")
        field.isAccessible = true
        @Suppress("UNCHECKED_CAST")
        val sources = field.get(ExtensionLoader) as ConcurrentHashMap<Long, Source>
        for (id in 101L..103L) sources[id] = FixtureSource(id)
        val fixture = FixtureSource(104)
        sources[104] = object : HttpSource(), Source by fixture {
            override val id = 104L
            override val name = fixture.name
            override val lang = "en"
            override val supportsLatest = false
            override val baseUrl = "http://fixture"
            override fun headersBuilder() = Headers.Builder()
            override fun getMangaUrl(manga: SManga) = baseUrl + manga.url
            override fun getChapterUrl(chapter: SChapter) = baseUrl + chapter.url
            override val client = imageClient
        }
    }
    @JvmStatic fun started(id: Long): Boolean = started.contains(id)
    @JvmStatic fun ended(id: Long): Boolean = ended.contains(id)
    @JvmStatic fun releaseSecond() { release.complete(Unit) }
    @JvmStatic fun activeCount(): Int = Operations.activeCount
}
