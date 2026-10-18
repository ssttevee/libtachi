package dev.tachi.host

import eu.kanade.tachiyomi.source.online.HttpSource
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withContext
import kotlinx.serialization.builtins.ListSerializer
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.encodeToJsonElement
import kotlinx.serialization.json.jsonObject
import java.io.File

/**
 * The JNI surface. Every method is static, takes/returns UTF-8 byte arrays of
 * JSON, and never throws: results are wrapped as `{"ok": ...}` or
 * `{"error": {"type", "message", "stack"}}`.
 *
 * Signatures (for RegisterNatives / GetStaticMethodID):
 *   init([B)[B   install([B)[B   uninstall([B)[B   listExtensions()[B
 *   call(J[B[B)[B   fetchImage(J[B)[B   lastImageMime()[B   shutdown()V
 */
object Bridge {
    const val API_VERSION = 1

    private val json get() = TachiRuntime.json
    private val lastMime = ThreadLocal<String?>()

    @JvmStatic
    fun apiVersion(): Int = API_VERSION

    @JvmStatic
    fun init(configJson: ByteArray): ByteArray = guard {
        val config = json.decodeFromString(RuntimeConfig.serializer(), configJson.utf8())
        TachiRuntime.init(config)
        JsonObject(
            mapOf(
                "apiVersion" to JsonPrimitive(API_VERSION),
                "javaVersion" to JsonPrimitive(System.getProperty("java.version")),
                "supportedLibVersions" to json.encodeToJsonElement(ExtensionLoader.SUPPORTED_LIB_VERSIONS),
            ),
        )
    }

    @JvmStatic
    fun install(path: ByteArray): ByteArray = guard {
        json.encodeToJsonElement(ExtensionInfoDto.serializer(), ExtensionLoader.install(File(path.utf8())))
    }

    @JvmStatic
    fun uninstall(pkg: ByteArray): ByteArray = guard { JsonPrimitive(ExtensionLoader.uninstall(pkg.utf8())) }

    @JvmStatic
    fun listExtensions(): ByteArray = guard {
        json.encodeToJsonElement(ListSerializer(ExtensionInfoDto.serializer()), ExtensionLoader.list())
    }

    @JvmStatic
    fun call(sourceId: Long, method: ByteArray, argsJson: ByteArray): ByteArray = guard {
        val source = ExtensionLoader.source(sourceId)
        val args = argsJson.utf8().ifBlank { "{}" }.let { json.parseToJsonElement(it).jsonObject }
        SourceCalls.call(source, method.utf8(), args)
    }

    /**
     * Downloads a page image through the source's own client (headers, cookies,
     * interceptors). Returns the raw bytes or null; on null, the error is
     * available via [lastError]. The MIME type is available via [lastImageMime].
     */
    @JvmStatic
    fun fetchImage(sourceId: Long, pageJson: ByteArray): ByteArray? {
        lastError.set(null)
        lastMime.set(null)
        return try {
            val source = ExtensionLoader.source(sourceId) as? HttpSource
                ?: throw IllegalArgumentException("Source $sourceId is not an HttpSource")
            val page = json.decodeFromString(PageDto.serializer(), pageJson.utf8()).toPage()
            runBlocking {
                withContext(Dispatchers.IO) {
                    if (page.imageUrl == null) page.imageUrl = source.getImageUrl(page)
                    source.getImage(page).use { response ->
                        lastMime.set(response.body.contentType()?.toString() ?: response.header("Content-Type"))
                        response.body.bytes()
                    }
                }
            }
        } catch (t: Throwable) {
            lastError.set(json.encodeToString(ErrorDto.serializer(), t.toErrorDto()).toByteArray())
            null
        }
    }

    @JvmStatic
    fun lastImageMime(): ByteArray? = lastMime.get()?.toByteArray()

    private val lastError = ThreadLocal<ByteArray?>()

    /** JSON ErrorDto describing why the previous [fetchImage] on this thread returned null. */
    @JvmStatic
    fun lastError(): ByteArray? = lastError.get()

    @JvmStatic
    fun shutdown() {
        for (ext in ExtensionLoader.list()) ExtensionLoader.uninstall(ext.pkg)
    }

    // ---- plumbing ----------------------------------------------------------------

    private inline fun guard(block: () -> JsonElement): ByteArray {
        val result: JsonObject = try {
            JsonObject(mapOf("ok" to block()))
        } catch (t: Throwable) {
            TachiLog.d("tachi", "bridge call failed: $t")
            JsonObject(mapOf("error" to json.encodeToJsonElement(ErrorDto.serializer(), t.toErrorDto())))
        }
        return json.encodeToString(JsonObject.serializer(), result).toByteArray(Charsets.UTF_8)
    }

    private fun Throwable.toErrorDto(): ErrorDto {
        val root = generateSequence(this) { it.cause?.takeIf { c -> c !== it } }.last()
        val message = buildString {
            append(this@toErrorDto.message ?: this@toErrorDto.javaClass.simpleName)
            if (root !== this@toErrorDto && root.message != null && root.message != this@toErrorDto.message) {
                append(" (caused by ").append(root.javaClass.simpleName).append(": ").append(root.message).append(')')
            }
        }
        return ErrorDto(type = javaClass.name, message = message, stack = stackTraceToString())
    }

    private fun ByteArray.utf8() = String(this, Charsets.UTF_8)
}
