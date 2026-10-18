// Mirrors extensions-lib 1.6 `eu.kanade.tachiyomi.source.CatalogueSource` (Apache-2.0).
package eu.kanade.tachiyomi.source

import eu.kanade.tachiyomi.source.model.SManga

interface CatalogueSource : Source {
    override val lang: String

    val supportsRelatedMangas: Boolean get() = false

    val disableRelatedMangasBySearch: Boolean get() = false

    val disableRelatedMangas: Boolean get() = false

    suspend fun fetchRelatedMangaList(manga: SManga): List<SManga> = throw UnsupportedOperationException("Unsupported!")
}
