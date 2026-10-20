// Mihon's backup model classes, copied from mihonapp/mihon 487c313
// (app/src/main/java/eu/kanade/tachiyomi/data/backup/models, Apache-2.0)
// without their conversion helpers, to write a backup exactly as Mihon's
// kotlinx.serialization ProtoBuf does. src/backup.zig decodes the result and
// must re-encode it byte for byte.
@file:OptIn(ExperimentalSerializationApi::class)

package dev.tachi.host.mihon

import kotlinx.serialization.ExperimentalSerializationApi
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.encodeToByteArray
import kotlinx.serialization.decodeFromByteArray
import kotlinx.serialization.protobuf.ProtoBuf
import kotlinx.serialization.protobuf.ProtoNumber
import java.io.File

val JsonObjectEmptyBytes = byteArrayOf(0x7B, 0x7D)

@Serializable
enum class UpdateStrategy { ALWAYS_UPDATE, ONLY_FETCH_ONCE }

@Serializable
data class Backup(
    @ProtoNumber(1) val backupManga: List<BackupManga>,
    @ProtoNumber(2) var backupCategories: List<BackupCategory> = emptyList(),
    @ProtoNumber(101) var backupSources: List<BackupSource> = emptyList(),
    @ProtoNumber(104) var backupPreferences: List<BackupPreference> = emptyList(),
    @ProtoNumber(105) var backupSourcePreferences: List<BackupSourcePreferences> = emptyList(),
    @ProtoNumber(106) var backupExtensionStores: List<BackupExtensionStore> = emptyList(),
)

@Serializable
class BackupExtensionStore(
    @ProtoNumber(1) var indexUrl: String,
    @ProtoNumber(2) var name: String,
    @ProtoNumber(3) var badgeLabel: String?,
    @ProtoNumber(5) var signingKey: String,
    @ProtoNumber(4) var contactWebsite: String,
    @ProtoNumber(6) var contactDiscord: String?,
    @ProtoNumber(7) var isLegacy: Boolean?,
    @ProtoNumber(8) var extensionListUrl: String?,
)

// Mihon's classes carry no @SerialName, so kotlinx names them by their
// package there; the names here say so explicitly.
@Serializable
data class BackupPreference(
    @ProtoNumber(1) val key: String,
    @ProtoNumber(2) val value: PreferenceValue,
)

@Serializable
data class BackupSourcePreferences(
    @ProtoNumber(1) val sourceKey: String,
    @ProtoNumber(2) val prefs: List<BackupPreference>,
)

@Serializable
sealed class PreferenceValue

@Serializable
@SerialName("eu.kanade.tachiyomi.data.backup.models.IntPreferenceValue")
data class IntPreferenceValue(val value: Int) : PreferenceValue()

@Serializable
@SerialName("eu.kanade.tachiyomi.data.backup.models.LongPreferenceValue")
data class LongPreferenceValue(val value: Long) : PreferenceValue()

@Serializable
@SerialName("eu.kanade.tachiyomi.data.backup.models.FloatPreferenceValue")
data class FloatPreferenceValue(val value: Float) : PreferenceValue()

@Serializable
@SerialName("eu.kanade.tachiyomi.data.backup.models.StringPreferenceValue")
data class StringPreferenceValue(val value: String) : PreferenceValue()

@Serializable
@SerialName("eu.kanade.tachiyomi.data.backup.models.BooleanPreferenceValue")
data class BooleanPreferenceValue(val value: Boolean) : PreferenceValue()

@Serializable
@SerialName("eu.kanade.tachiyomi.data.backup.models.StringSetPreferenceValue")
data class StringSetPreferenceValue(val value: Set<String>) : PreferenceValue()

@Serializable
class BackupManga(
    @ProtoNumber(1) var source: Long,
    @ProtoNumber(2) var url: String,
    @ProtoNumber(3) var title: String = "",
    @ProtoNumber(4) var artist: String? = null,
    @ProtoNumber(5) var author: String? = null,
    @ProtoNumber(6) var description: String? = null,
    @ProtoNumber(7) var genre: List<String> = emptyList(),
    @ProtoNumber(8) var status: Int = 0,
    @ProtoNumber(9) var thumbnailUrl: String? = null,
    @ProtoNumber(13) var dateAdded: Long = 0,
    @ProtoNumber(14) var viewer: Int = 0,
    @ProtoNumber(16) var chapters: List<BackupChapter> = emptyList(),
    @ProtoNumber(17) var categories: List<Long> = emptyList(),
    @ProtoNumber(18) var tracking: List<BackupTracking> = emptyList(),
    @ProtoNumber(100) var favorite: Boolean = true,
    @ProtoNumber(101) var chapterFlags: Int = 0,
    @ProtoNumber(103) var viewer_flags: Int? = null,
    @ProtoNumber(104) var history: List<BackupHistory> = emptyList(),
    @ProtoNumber(105) var updateStrategy: UpdateStrategy = UpdateStrategy.ALWAYS_UPDATE,
    @ProtoNumber(107) var favoriteModifiedAt: Long? = null,
    @ProtoNumber(108) var excludedScanlators: List<String> = emptyList(),
    @ProtoNumber(110) var notes: String = "",
    @ProtoNumber(111) var initialized: Boolean = false,
    @ProtoNumber(112) var memo: ByteArray = JsonObjectEmptyBytes,
    @ProtoNumber(113) var nextUpdate: Long = 0,
)

@Serializable
class BackupChapter(
    @ProtoNumber(1) var url: String,
    @ProtoNumber(2) var name: String,
    @ProtoNumber(3) var scanlator: String? = null,
    @ProtoNumber(4) var read: Boolean = false,
    @ProtoNumber(5) var bookmark: Boolean = false,
    @ProtoNumber(6) var lastPageRead: Long = 0,
    @ProtoNumber(7) var dateFetch: Long = 0,
    @ProtoNumber(8) var dateUpload: Long = 0,
    @ProtoNumber(9) var chapterNumber: Float = 0F,
    @ProtoNumber(10) var sourceOrder: Long = 0,
    @ProtoNumber(13) var memo: ByteArray = JsonObjectEmptyBytes,
)

@Serializable
class BackupCategory(
    @ProtoNumber(1) var name: String,
    @ProtoNumber(2) var order: Long = 0,
    @ProtoNumber(3) var id: Long = 0,
    @ProtoNumber(100) var flags: Long = 0,
)

@Serializable
data class BackupHistory(
    @ProtoNumber(1) var url: String,
    @ProtoNumber(2) var lastRead: Long,
    @ProtoNumber(3) var readDuration: Long = 0,
)

@Serializable
data class BackupSource(
    @ProtoNumber(1) var name: String = "",
    @ProtoNumber(2) var sourceId: Long,
)

@Serializable
data class BackupTracking(
    @ProtoNumber(1) var syncId: Int,
    @ProtoNumber(2) var libraryId: Long,
    @ProtoNumber(3) var mediaIdInt: Int = 0,
    @ProtoNumber(4) var trackingUrl: String = "",
    @ProtoNumber(5) var title: String = "",
    @ProtoNumber(6) var lastChapterRead: Float = 0F,
    @ProtoNumber(7) var totalChapters: Int = 0,
    @ProtoNumber(8) var score: Float = 0F,
    @ProtoNumber(9) var status: Int = 0,
    @ProtoNumber(10) var startedReadingDate: Long = 0,
    @ProtoNumber(11) var finishedReadingDate: Long = 0,
    @ProtoNumber(12) var private: Boolean = false,
    @ProtoNumber(100) var mediaId: Long = 0,
)

/** A backup touching every field kind: negatives, nullables, floats, repeats, a non-default enum. */
fun sample() = Backup(
    backupManga = listOf(
        BackupManga(
            source = 2499283573021220255L,
            url = "/title/abc",
            title = "Solo Leveling ☆",
            artist = "Dubu",
            description = "desc",
            genre = listOf("Action", "Fantasy"),
            status = 2,
            thumbnailUrl = "https://x/c.jpg",
            dateAdded = 1700000000000L,
            chapters = listOf(
                BackupChapter(url = "/c/1", name = "Chapter 1", scanlator = "Group", read = true, lastPageRead = 7, dateFetch = 1700000000001L, dateUpload = 1690000000000L, chapterNumber = 1f, sourceOrder = 1),
                BackupChapter(url = "/c/2", name = "Chapter 2.5", chapterNumber = 2.5f, memo = "{\"k\":1}".encodeToByteArray()),
            ),
            categories = listOf(0, 2),
            tracking = listOf(
                BackupTracking(syncId = 2, libraryId = 0, trackingUrl = "https://anilist.co/manga/1", title = "Solo", lastChapterRead = 1.5f, totalChapters = 200, score = 8.5f, status = 1, startedReadingDate = 1690000000000L, private = true, mediaId = 105398),
            ),
            chapterFlags = 0x100,
            viewer_flags = 2,
            history = listOf(BackupHistory("/c/1", 1700000005000L, 60000)),
            updateStrategy = UpdateStrategy.ONLY_FETCH_ONCE,
            excludedScanlators = listOf("Bad"),
            notes = "note",
            initialized = true,
            nextUpdate = -1,
        ),
        BackupManga(
            source = 0,
            url = "Mine",
            favorite = false,
            chapters = listOf(BackupChapter(url = "Mine/1", name = "1", lastPageRead = 3)),
        ),
    ),
    backupCategories = listOf(BackupCategory("Reading", order = 2, id = 5, flags = 64), BackupCategory("Later", id = 6)),
    backupSources = listOf(BackupSource("MangaDex", 2499283573021220255L)),
    backupPreferences = listOf(
        BackupPreference("remove_after_read_slots", IntPreferenceValue(-1)),
        BackupPreference("download_parallel_page_limit", IntPreferenceValue(0)),
        BackupPreference("default_chapter_sort_by_source_or_number", LongPreferenceValue(256)),
        BackupPreference("float_pref", FloatPreferenceValue(1.5f)),
        BackupPreference("library_sorting_mode", StringPreferenceValue("UNREAD_COUNT,DESCENDING")),
        BackupPreference("skip_read", BooleanPreferenceValue(false)),
        BackupPreference("download_new", BooleanPreferenceValue(true)),
        BackupPreference("library_update_manga_restriction", StringSetPreferenceValue(setOf("manga_ongoing", "manga_started"))),
        BackupPreference("hidden_catalogues", StringSetPreferenceValue(emptySet())),
    ),
    backupSourcePreferences = listOf(
        BackupSourcePreferences("source_2499283573021220255", listOf(BackupPreference("dataSaver", BooleanPreferenceValue(true)))),
    ),
    backupExtensionStores = listOf(
        BackupExtensionStore("https://raw.githubusercontent.com/keiyoushi/extensions/repo/index.min.json", "Keiyoushi", "KEI", "9add655a", "https://keiyoushi.github.io", "https://discord.gg/x", false, "https://k/list.pb"),
        BackupExtensionStore("https://old/repo.json", "Old", null, "", "", null, null, null),
    ),
)

object MihonBackupGolden {
    @JvmStatic fun main(args: Array<String>) {
        val golden = File(System.getProperty("tachi.golden"))
        val bytes = ProtoBuf.encodeToByteArray(sample())
        // The bytes must also read back as the same backup.
        val back = ProtoBuf.decodeFromByteArray<Backup>(bytes)
        check(back.backupManga[0].title == "Solo Leveling ☆")
        check(back.backupPreferences[0].value == IntPreferenceValue(-1))
        if (System.getProperty("tachi.writeGolden") == "true") {
            golden.parentFile.mkdirs()
            golden.writeBytes(bytes)
            println("Wrote ${bytes.size} bytes to $golden")
            return
        }
        check(golden.readBytes().contentEquals(bytes)) { "$golden differs from kotlinx's encoding; rerun with -PwriteGolden=true if the sample changed" }
        println("Mihon backup golden matches kotlinx.serialization (${bytes.size} bytes)")
    }
}
