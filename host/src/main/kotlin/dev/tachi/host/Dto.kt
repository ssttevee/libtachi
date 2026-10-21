package dev.tachi.host

import eu.kanade.tachiyomi.source.model.Filter
import eu.kanade.tachiyomi.source.model.FilterList
import eu.kanade.tachiyomi.source.model.MangasPage
import eu.kanade.tachiyomi.source.model.Page
import eu.kanade.tachiyomi.source.model.SChapter
import eu.kanade.tachiyomi.source.model.SManga
import eu.kanade.tachiyomi.source.model.SMangaUpdate
import eu.kanade.tachiyomi.source.model.UpdateStrategy
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.boolean
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.int
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive

// ---------------------------------------------------------------------------
// Wire format shared with the native side. Keep in sync with docs/API.md and
// src/models.zig. Source ids are 63-bit; they are serialised as strings so
// JavaScript/JSON consumers do not lose precision.
// ---------------------------------------------------------------------------

@Serializable
data class MangaDto(
    val url: String,
    val title: String,
    val thumbnailUrl: String? = null,
    val artist: String? = null,
    val author: String? = null,
    val status: Int = SManga.UNKNOWN,
    val description: String? = null,
    val genre: String? = null,
    val updateStrategy: String = UpdateStrategy.ALWAYS_UPDATE.name,
    val initialized: Boolean = false,
    val memo: JsonObject? = null,
)

@Serializable
data class ChapterDto(
    val url: String,
    val name: String,
    val chapterNumber: Float = -1f,
    val scanlator: String? = null,
    val dateUpload: Long = 0,
    val memo: JsonObject? = null,
)

@Serializable
data class PageDto(
    val index: Int,
    val url: String = "",
    val imageUrl: String? = null,
)

@Serializable
data class MangasPageDto(val mangas: List<MangaDto>, val hasNextPage: Boolean)

@Serializable
data class MangaUpdateDto(val manga: MangaDto, val chapters: List<ChapterDto>)

@Serializable
data class SourceInfoDto(
    val id: String,
    val name: String,
    val lang: String,
    val baseUrl: String? = null,
    val supportsLatest: Boolean,
    val isConfigurable: Boolean,
    val supportsRelatedMangas: Boolean = false,
    val className: String,
    val extensionPkg: String,
)

@Serializable
data class ExtensionInfoDto(
    val pkg: String,
    val name: String,
    val versionName: String,
    val versionCode: Int,
    val libVersion: String,
    val nsfw: Boolean,
    val lang: String,
    val path: String,
    val sources: List<SourceInfoDto>,
    /** `tachiyomi.extension.class` entries; lets a restore defer loading until a source is used. */
    val sourceClasses: List<String> = emptyList(),
)

/**
 * A search filter. `type` is one of header, separator, select, text, checkbox,
 * tristate, group, sort. `state` depends on the type: int for select/tristate,
 * string for text, bool for checkbox, {index, ascending} or null for sort,
 * and absent for group (use `filters`).
 */
@Serializable
data class FilterDto(
    val type: String,
    val name: String,
    val state: JsonElement? = null,
    val values: List<String>? = null,
    val filters: List<FilterDto>? = null,
)

/** A preference exposed by a ConfigurableSource. `type`: switch, checkbox, list, multiselect, edittext, category, other. */
@Serializable
data class PreferenceDto(
    val type: String,
    val key: String?,
    val title: String?,
    val summary: String?,
    val defaultValue: JsonElement? = null,
    val value: JsonElement? = null,
    val entries: List<String>? = null,
    val entryValues: List<String>? = null,
    val dialogTitle: String? = null,
    val dialogMessage: String? = null,
    val enabled: Boolean = true,
    val visible: Boolean = true,
)

@Serializable
data class ErrorDto(val type: String, val message: String?, val stack: String? = null, val code: String? = null)

// ---------------------------------------------------------------------------
// Conversions
// ---------------------------------------------------------------------------

fun SManga.toDto() = MangaDto(
    url = url,
    title = title,
    thumbnailUrl = thumbnail_url,
    artist = artist,
    author = author,
    status = status,
    description = description,
    genre = genre,
    updateStrategy = update_strategy.name,
    initialized = initialized,
    memo = memo.takeIf { it.isNotEmpty() },
)

fun MangaDto.toSManga(): SManga = SManga.create().also {
    it.url = url
    it.title = title
    it.thumbnail_url = thumbnailUrl
    it.artist = artist
    it.author = author
    it.status = status
    it.description = description
    it.genre = genre
    it.update_strategy = runCatching { UpdateStrategy.valueOf(updateStrategy) }.getOrDefault(UpdateStrategy.ALWAYS_UPDATE)
    it.initialized = initialized
    it.memo = memo ?: JsonObject(emptyMap())
}

fun SChapter.toDto() = ChapterDto(
    url = url,
    name = name,
    chapterNumber = chapter_number,
    scanlator = scanlator,
    dateUpload = date_upload,
    memo = memo.takeIf { it.isNotEmpty() },
)

fun ChapterDto.toSChapter(): SChapter = SChapter.create().also {
    it.url = url
    it.name = name
    it.chapter_number = chapterNumber
    it.scanlator = scanlator
    it.date_upload = dateUpload
    it.memo = memo ?: JsonObject(emptyMap())
}

fun Page.toDto() = PageDto(index = index, url = url, imageUrl = imageUrl)

fun PageDto.toPage() = Page(index = index, url = url, imageUrl = imageUrl)

fun MangasPage.toDto() = MangasPageDto(mangas.map { it.toDto() }, hasNextPage)

fun SMangaUpdate.toDto() = MangaUpdateDto(manga.toDto(), chapters.map { it.toDto() })

// ---- filters ----------------------------------------------------------------

fun Filter<*>.toDto(): FilterDto = when (this) {
    is Filter.Header -> FilterDto("header", name)
    is Filter.Separator -> FilterDto("separator", name)
    is Filter.Select<*> -> FilterDto("select", name, JsonPrimitive(state), values.map { it.toString() })
    is Filter.Text -> FilterDto("text", name, JsonPrimitive(state))
    is Filter.CheckBox -> FilterDto("checkbox", name, JsonPrimitive(state))
    is Filter.TriState -> FilterDto("tristate", name, JsonPrimitive(state))
    is Filter.Group<*> -> FilterDto("group", name, filters = state.map { (it as Filter<*>).toDto() })
    is Filter.Sort -> FilterDto(
        "sort",
        name,
        state?.let { JsonObject(mapOf("index" to JsonPrimitive(it.index), "ascending" to JsonPrimitive(it.ascending))) }
            ?: JsonNull,
        values.toList(),
    )
}

fun FilterList.toDto(): List<FilterDto> = list.map { it.toDto() }

/**
 * Applies user-chosen states onto a freshly created filter list. Filters are
 * matched by position, so the client must send the list in the order it was received.
 */
@Suppress("UNCHECKED_CAST")
fun applyFilterStates(filters: List<Filter<*>>, states: List<FilterDto>) {
    for ((filter, dto) in filters.zip(states)) {
        val state = dto.state
        when (filter) {
            is Filter.Group<*> -> dto.filters?.let { applyFilterStates(filter.state as List<Filter<*>>, it) }
            is Filter.Select<*> -> state?.jsonPrimitive?.int?.let { (filter as Filter<Int>).state = it }
            is Filter.TriState -> state?.jsonPrimitive?.int?.let { filter.state = it }
            is Filter.Text -> state?.jsonPrimitive?.contentOrNull?.let { filter.state = it }
            is Filter.CheckBox -> state?.jsonPrimitive?.booleanOrNull?.let { filter.state = it }
            is Filter.Sort -> {
                filter.state = when (state) {
                    null, is JsonNull -> null
                    else -> state.jsonObject.let {
                        Filter.Sort.Selection(it["index"]!!.jsonPrimitive.int, it["ascending"]!!.jsonPrimitive.boolean)
                    }
                }
            }
            is Filter.Header, is Filter.Separator -> Unit
        }
    }
}

// ---- json helpers ------------------------------------------------------------

fun JsonElement.asAny(): Any? = when (this) {
    is JsonNull -> null
    is JsonPrimitive -> when {
        isString -> content
        booleanOrNull != null -> boolean
        content.toIntOrNull() != null -> int
        content.toLongOrNull() != null -> content.toLong()
        else -> content.toDoubleOrNull() ?: content
    }
    is JsonArray -> map { it.asAny() }
    is JsonObject -> mapValues { it.value.asAny() }
}

fun Any?.toJsonElement(): JsonElement = when (this) {
    null -> JsonNull
    is JsonElement -> this
    is String -> JsonPrimitive(this)
    is Boolean -> JsonPrimitive(this)
    is Number -> JsonPrimitive(this)
    is CharSequence -> JsonPrimitive(toString())
    is Array<*> -> JsonArray(map { it.toJsonElement() })
    is Iterable<*> -> JsonArray(map { it.toJsonElement() })
    is Map<*, *> -> JsonObject(entries.associate { it.key.toString() to it.value.toJsonElement() })
    else -> JsonPrimitive(toString())
}
