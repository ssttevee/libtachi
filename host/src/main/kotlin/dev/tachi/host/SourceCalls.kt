package dev.tachi.host

import android.content.Context
import androidx.preference.CheckBoxPreference
import androidx.preference.EditTextPreference
import androidx.preference.ListPreference
import androidx.preference.MultiSelectListPreference
import androidx.preference.Preference
import androidx.preference.PreferenceCategory
import androidx.preference.PreferenceGroup
import androidx.preference.PreferenceManager
import androidx.preference.PreferenceScreen
import androidx.preference.SwitchPreference
import androidx.preference.SwitchPreferenceCompat
import androidx.preference.TwoStatePreference
import eu.kanade.tachiyomi.source.CatalogueSource
import eu.kanade.tachiyomi.source.ConfigurableSource
import eu.kanade.tachiyomi.source.Source
import eu.kanade.tachiyomi.source.model.FilterList
import eu.kanade.tachiyomi.source.model.SManga
import eu.kanade.tachiyomi.source.online.HttpSource
import eu.kanade.tachiyomi.source.sourcePreferences
import kotlinx.serialization.builtins.ListSerializer
import kotlinx.serialization.builtins.serializer
import okhttp3.HttpUrl.Companion.toHttpUrl
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.decodeFromJsonElement
import kotlinx.serialization.json.encodeToJsonElement
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonPrimitive

/** Dispatches a JSON-described method call onto a loaded source. */
object SourceCalls {
    private val json get() = TachiRuntime.json

    fun call(source: Source, method: String, args: JsonObject): JsonElement = Operations.blocking {
        dispatch(source, method, args)
    }

    private suspend fun dispatch(source: Source, method: String, args: JsonObject): JsonElement = with(ExtensionLoader) {
        when (method) {
            "info" -> json.encodeToJsonElement(source.toInfo(ExtensionLoader.list().firstOrNull { e ->
                e.sources.any { it.id == source.id.toString() }
            }?.pkg ?: ""))

            "popular" -> json.encodeToJsonElement(source.getPopularManga(args.int("page", 1)).toDto())

            "latest" -> json.encodeToJsonElement(source.getLatestUpdates(args.int("page", 1)).toDto())

            "search" -> {
                val filters = source.getFilterList()
                args["filters"]?.takeUnless { it is JsonNull }?.let { el ->
                    applyFilterStates(filters.list, json.decodeFromJsonElement(ListSerializer(FilterDto.serializer()), el))
                }
                json.encodeToJsonElement(
                    source.getSearchManga(args.int("page", 1), args.string("query") ?: "", filters).toDto(),
                )
            }

            "update" -> {
                val manga = args.manga("manga")
                val update = source.getMangaUpdate(
                    manga = manga,
                    chapters = args.chapters("chapters"),
                    fetchDetails = args.bool("fetchDetails", true),
                    fetchChapters = args.bool("fetchChapters", true),
                )
                update.manga.keepIdentityOf(manga)
                json.encodeToJsonElement(update.toDto())
            }

            "details" -> {
                val manga = args.manga("manga")
                json.encodeToJsonElement(
                    source.getMangaUpdate(manga, emptyList(), fetchDetails = true, fetchChapters = false)
                        .manga.keepIdentityOf(manga).toDto(),
                )
            }

            "chapters" -> json.encodeToJsonElement(
                ListSerializer(ChapterDto.serializer()),
                source.getMangaUpdate(args.manga("manga"), emptyList(), fetchDetails = false, fetchChapters = true)
                    .chapters.map { it.toDto() },
            )

            "pages" -> json.encodeToJsonElement(
                ListSerializer(PageDto.serializer()),
                source.getPageList(args.chapter("chapter")).map { it.toDto() },
            )

            "imageRequests" -> json.encodeToJsonElement(
                ListSerializer(ImageRequestDto.serializer()),
                ImageRequests.plan(http(source), args.chapter("chapter")),
            )

            "imageCookies" -> {
                val url = args.string("url")!!.toHttpUrl()
                val cookies = args["cookies"]!!.jsonArray.mapNotNull { okhttp3.Cookie.parse(url, it.jsonPrimitive.content) }
                http(source).client.cookieJar.saveFromResponse(url, cookies)
                JsonPrimitive(true)
            }

            "cancel" -> { http(source).client.dispatcher.cancelAll(); JsonPrimitive(true) }

            "imageUrl" -> JsonPrimitive(http(source).getImageUrl(args.page("page")))

            "related" -> json.encodeToJsonElement(
                ListSerializer(MangaDto.serializer()),
                catalogue(source).fetchRelatedMangaList(args.manga("manga")).map { it.toDto() },
            )

            "filters" -> json.encodeToJsonElement(ListSerializer(FilterDto.serializer()), source.getFilterList().toDto())

            "mangaUrl" -> JsonPrimitive(http(source).getMangaUrl(args.manga("manga")))

            "chapterUrl" -> JsonPrimitive(http(source).getChapterUrl(args.chapter("chapter")))

            "preferences" -> json.encodeToJsonElement(ListSerializer(PreferenceDto.serializer()), preferences(source))

            "setPreference" -> json.encodeToJsonElement(
                ListSerializer(PreferenceDto.serializer()),
                setPreference(source, args.string("key") ?: error("key is required"), args["value"] ?: JsonNull),
            )

            else -> throw IllegalArgumentException("Unknown method '$method'")
        }
    }

    // ---- preferences -------------------------------------------------------------

    private fun buildScreen(source: ConfigurableSource): PreferenceScreen {
        val context = TachiRuntime.application as Context
        val manager = PreferenceManager(context).also { it.sharedPreferences = source.sourcePreferences() }
        val screen = PreferenceScreen(context, manager)
        source.setupPreferenceScreen(screen)
        return screen
    }

    private fun flatten(group: PreferenceGroup): List<Preference> =
        group.preferences.flatMap { p -> if (p is PreferenceGroup) listOf(p) + flatten(p) else listOf(p) }

    fun preferences(source: Source): List<PreferenceDto> {
        val configurable = source as? ConfigurableSource ?: return emptyList()
        val screen = buildScreen(configurable)
        val prefs = configurable.sourcePreferences()
        return flatten(screen).map { p ->
            val key = p.key
            val current: JsonElement? = key?.let { k ->
                when (p) {
                    is TwoStatePreference -> JsonPrimitive(prefs.getBoolean(k, (p.defaultValue as? Boolean) ?: false))
                    is MultiSelectListPreference -> prefs.getStringSet(k, null)?.let { set -> JsonArray(set.map { JsonPrimitive(it) }) }
                    else -> prefs.all[k]?.toJsonElement()
                }
            }
            PreferenceDto(
                type = when (p) {
                    is SwitchPreferenceCompat, is SwitchPreference -> "switch"
                    is CheckBoxPreference -> "checkbox"
                    is ListPreference -> "list"
                    is MultiSelectListPreference -> "multiselect"
                    is EditTextPreference -> "edittext"
                    is PreferenceCategory -> "category"
                    else -> "other"
                },
                key = key,
                title = p.title?.toString(),
                summary = runCatching { p.summary?.toString() }.getOrNull(),
                defaultValue = p.defaultValue?.toJsonElement(),
                value = current,
                entries = (p as? ListPreference)?.entries?.map { it.toString() }
                    ?: (p as? MultiSelectListPreference)?.entries?.map { it.toString() },
                entryValues = (p as? ListPreference)?.entryValues?.map { it.toString() }
                    ?: (p as? MultiSelectListPreference)?.entryValues?.map { it.toString() },
                dialogTitle = (p as? androidx.preference.DialogPreference)?.dialogTitle?.toString(),
                dialogMessage = (p as? androidx.preference.DialogPreference)?.dialogMessage?.toString(),
                enabled = p.isEnabled,
                visible = p.isVisible,
            )
        }
    }

    /** Mirrors what the Android preference UI does: ask the change listener, then persist. */
    fun setPreference(source: Source, key: String, value: JsonElement): List<PreferenceDto> {
        val configurable = source as? ConfigurableSource
            ?: throw IllegalArgumentException("${source.name} is not configurable")
        val screen = buildScreen(configurable)
        val pref = flatten(screen).firstOrNull { it.key == key }
            ?: throw NoSuchElementException("No preference with key '$key'")
        val prefs = configurable.sourcePreferences()
        when (pref) {
            is TwoStatePreference -> {
                val v = value.jsonPrimitive.booleanOrNull ?: error("boolean expected")
                if (pref.callChangeListener(v)) prefs.edit().putBoolean(key, v).apply()
            }
            is MultiSelectListPreference -> {
                val v = value.jsonArray.map { it.jsonPrimitive.content }.toMutableSet()
                if (pref.callChangeListener(v)) prefs.edit().putStringSet(key, v).apply()
            }
            is ListPreference, is EditTextPreference -> {
                val v = value.jsonPrimitive.contentOrNull ?: ""
                if (pref.callChangeListener(v)) prefs.edit().putString(key, v).apply()
            }
            else -> {
                val v = value.asAny()
                if (pref.callChangeListener(v)) {
                    val editor = prefs.edit()
                    when (v) {
                        null -> editor.remove(key)
                        is Boolean -> editor.putBoolean(key, v)
                        is Int -> editor.putInt(key, v)
                        is Long -> editor.putLong(key, v)
                        is Double -> editor.putFloat(key, v.toFloat())
                        is List<*> -> editor.putStringSet(key, v.map { it.toString() }.toMutableSet())
                        else -> editor.putString(key, v.toString())
                    }
                    editor.apply()
                }
            }
        }
        return preferences(source)
    }

    // ---- helpers -----------------------------------------------------------------

    /**
     * Mihon keeps the stored URL, and the stored title when the parsed one is
     * blank; many extensions' mangaDetailsParse relies on that.
     */
    private fun SManga.keepIdentityOf(original: SManga): SManga {
        if (runCatching { url }.isFailure) url = original.url
        if (runCatching { title }.getOrNull().isNullOrBlank()) title = original.title
        return this
    }

    private fun http(source: Source): HttpSource =
        source as? HttpSource ?: throw IllegalArgumentException("${source.name} is not an HttpSource")

    private fun catalogue(source: Source): CatalogueSource =
        source as? CatalogueSource ?: throw IllegalArgumentException("${source.name} is not a CatalogueSource")

    private fun JsonObject.int(key: String, default: Int): Int = this[key]?.jsonPrimitive?.intOrNull ?: default

    private fun JsonObject.bool(key: String, default: Boolean): Boolean = this[key]?.jsonPrimitive?.booleanOrNull ?: default

    private fun JsonObject.string(key: String): String? = this[key]?.takeUnless { it is JsonNull }?.jsonPrimitive?.contentOrNull

    private fun JsonObject.manga(key: String) =
        json.decodeFromJsonElement(MangaDto.serializer(), this[key] ?: error("'$key' is required")).toSManga()

    private fun JsonObject.chapter(key: String) =
        json.decodeFromJsonElement(ChapterDto.serializer(), this[key] ?: error("'$key' is required")).toSChapter()

    private fun JsonObject.page(key: String) =
        json.decodeFromJsonElement(PageDto.serializer(), this[key] ?: error("'$key' is required")).toPage()

    private fun JsonObject.chapters(key: String) = this[key]?.takeUnless { it is JsonNull }?.let {
        json.decodeFromJsonElement(ListSerializer(ChapterDto.serializer()), it).map { c -> c.toSChapter() }
    } ?: emptyList()
}
