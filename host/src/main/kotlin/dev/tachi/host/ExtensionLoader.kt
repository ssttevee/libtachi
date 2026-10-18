package dev.tachi.host

import com.googlecode.d2j.dex.Dex2jar
import com.googlecode.d2j.reader.MultiDexFileReader
import com.googlecode.dex2jar.tools.BaksmaliBaseDexExceptionHandler
import eu.kanade.tachiyomi.source.CatalogueSource
import eu.kanade.tachiyomi.source.ConfigurableSource
import eu.kanade.tachiyomi.source.Source
import eu.kanade.tachiyomi.source.SourceFactory
import eu.kanade.tachiyomi.source.online.HttpSource
import net.dongliu.apk.parser.ApkFile
import org.w3c.dom.Element
import java.io.File
import java.net.URLClassLoader
import java.util.concurrent.ConcurrentHashMap
import java.util.zip.ZipFile
import javax.xml.parsers.DocumentBuilderFactory

class ExtensionLoadException(message: String, cause: Throwable? = null) : Exception(message, cause)

/**
 * Loads Mihon/Tachiyomi extension packages into the running JVM.
 *
 * Two package forms are accepted:
 *  - `.jar`: JVM bytecode plus a plain-text AndroidManifest.xml. This is what
 *    the Keiyoushi repo publishes next to each APK (`index.pb` field 501).
 *  - `.apk`: Dalvik bytecode. Converted once with dex2jar into the cache dir.
 *
 * Mirrors Mihon's ExtensionLoader / Suwayomi's Extension.installExtension.
 */
object ExtensionLoader {
    const val EXTENSION_FEATURE = "tachiyomi.extension"
    const val METADATA_SOURCE_CLASS = "tachiyomi.extension.class"
    const val METADATA_SOURCE_FACTORY = "tachiyomi.extension.factory"
    const val METADATA_NSFW = "tachiyomi.extension.nsfw"
    const val METADATA_NAME = "tachiyomix.name"
    const val METADATA_EXTENSION_LIB = "tachiyomix.extensionLib"
    const val METADATA_CONTENT_WARNING = "tachiyomix.contentWarning"

    /** extensions-lib versions this host implements. 1.4/1.5 need RxJava and are not supported yet. */
    val SUPPORTED_LIB_VERSIONS = listOf("1.6")

    class LoadedExtension(
        val info: ExtensionInfoDto,
        val classLoader: URLClassLoader,
        val sources: List<Source>,
    )

    data class Manifest(
        val packageName: String,
        val versionName: String,
        val versionCode: Int,
        val features: List<String>,
        val metaData: Map<String, String>,
    )

    private val extensions = ConcurrentHashMap<String, LoadedExtension>()
    private val sourcesById = ConcurrentHashMap<Long, Source>()
    private val sourceOwner = ConcurrentHashMap<Long, String>()

    fun source(id: Long): Source = sourcesById[id] ?: throw NoSuchElementException("No loaded source with id $id")

    fun extension(pkg: String): LoadedExtension? = extensions[pkg]

    fun list(): List<ExtensionInfoDto> = extensions.values.map { it.info }.sortedBy { it.pkg }

    @Synchronized
    fun install(file: File): ExtensionInfoDto {
        if (!file.isFile) throw ExtensionLoadException("Extension file not found: $file")
        val manifest = readManifest(file)
        validate(manifest)

        val jar = if (containsDex(file)) convertApk(file, manifest) else file
        val loader = URLClassLoader(arrayOf(jar.toURI().toURL()), ExtensionLoader::class.java.classLoader)

        val classNames = manifest.metaData[METADATA_SOURCE_CLASS]!!
            .split(";")
            .map { it.trim() }
            .filter { it.isNotEmpty() }
            .map { if (it.startsWith(".")) manifest.packageName + it else it }

        val sources = try {
            classNames.flatMap { className ->
                when (val obj = Class.forName(className, false, loader).getDeclaredConstructor().newInstance()) {
                    is Source -> listOf(obj)
                    is SourceFactory -> obj.createSources()
                    else -> throw ExtensionLoadException("Unknown source class type: $className")
                }
            }
        } catch (e: ExtensionLoadException) {
            loader.close()
            throw e
        } catch (e: Throwable) {
            loader.close()
            throw ExtensionLoadException("Failed to instantiate sources of ${manifest.packageName}: $e", e)
        }

        // Replace a previously loaded version of the same package.
        extensions[manifest.packageName]?.let { unload(it) }

        val info = ExtensionInfoDto(
            pkg = manifest.packageName,
            name = manifest.metaData[METADATA_NAME] ?: manifest.packageName.substringAfterLast('.'),
            versionName = manifest.versionName,
            versionCode = manifest.versionCode,
            libVersion = libVersion(manifest),
            nsfw = isNsfw(manifest),
            lang = when (val langs = sources.map { it.lang }.distinct()) {
                emptyList<String>() -> ""
                else -> if (langs.size == 1) langs.first() else "all"
            },
            path = file.absolutePath,
            sources = sources.map { it.toInfo(manifest.packageName) },
        )
        val loaded = LoadedExtension(info, loader, sources)
        extensions[manifest.packageName] = loaded
        for (s in sources) {
            sourcesById[s.id] = s
            sourceOwner[s.id] = manifest.packageName
        }
        TachiLog.i("tachi", "loaded ${info.pkg} v${info.versionName} (${sources.size} source(s))")
        return info
    }

    @Synchronized
    fun uninstall(pkg: String): Boolean {
        val ext = extensions.remove(pkg) ?: return false
        unload(ext)
        return true
    }

    private fun unload(ext: LoadedExtension) {
        for (s in ext.sources) {
            if (sourceOwner[s.id] == ext.info.pkg) {
                sourcesById.remove(s.id)
                sourceOwner.remove(s.id)
            }
        }
        runCatching { ext.classLoader.close() }
    }

    fun Source.toInfo(pkg: String) = SourceInfoDto(
        id = id.toString(),
        name = name,
        lang = lang,
        baseUrl = (this as? HttpSource)?.baseUrl,
        supportsLatest = supportsLatest,
        isConfigurable = this is ConfigurableSource,
        supportsRelatedMangas = (this as? CatalogueSource)?.supportsRelatedMangas ?: false,
        className = javaClass.name,
        extensionPkg = pkg,
    )

    // ---- validation ------------------------------------------------------------

    private fun validate(m: Manifest) {
        if (EXTENSION_FEATURE !in m.features) {
            throw ExtensionLoadException("${m.packageName} is not a Tachiyomi extension (missing uses-feature $EXTENSION_FEATURE)")
        }
        val lib = libVersion(m)
        if (lib !in SUPPORTED_LIB_VERSIONS) {
            throw ExtensionLoadException(
                "${m.packageName} targets extensions-lib $lib; this host supports ${SUPPORTED_LIB_VERSIONS.joinToString()}",
            )
        }
        if (m.metaData[METADATA_SOURCE_CLASS].isNullOrBlank()) {
            throw ExtensionLoadException("${m.packageName} declares no $METADATA_SOURCE_CLASS")
        }
    }

    private fun libVersion(m: Manifest): String =
        m.metaData[METADATA_EXTENSION_LIB] ?: m.versionName.substringBeforeLast('.')

    private fun isNsfw(m: Manifest): Boolean {
        m.metaData[METADATA_CONTENT_WARNING]?.toIntOrNull()?.let { return it != 0 }
        return m.metaData[METADATA_NSFW]?.toIntOrNull() == 1
    }

    // ---- packaging -------------------------------------------------------------

    private fun containsDex(file: File): Boolean = ZipFile(file).use { it.getEntry("classes.dex") != null }

    fun readManifest(file: File): Manifest {
        val bytes = ZipFile(file).use { zip ->
            val entry = zip.getEntry("AndroidManifest.xml")
                ?: throw ExtensionLoadException("$file has no AndroidManifest.xml")
            zip.getInputStream(entry).readBytes()
        }
        // Binary AXML starts with 0x00080003; APKs always use it, keiyoushi jars ship plain XML.
        val isBinary = bytes.size >= 4 && bytes[0] == 0x03.toByte() && bytes[1] == 0x00.toByte() &&
            bytes[2] == 0x08.toByte() && bytes[3] == 0x00.toByte()
        val xml = if (isBinary) ApkFile(file).use { it.manifestXml } else String(bytes, Charsets.UTF_8)
        return parseManifestXml(xml)
    }

    private fun parseManifestXml(xml: String): Manifest {
        val doc = DocumentBuilderFactory.newInstance().newDocumentBuilder().parse(xml.byteInputStream())
        val root = doc.documentElement
        if (root.tagName != "manifest") throw ExtensionLoadException("Malformed AndroidManifest.xml")
        val features = root.getElementsByTagName("uses-feature").let { list ->
            (0 until list.length).mapNotNull { (list.item(it) as Element).getAttribute("android:name").ifEmpty { null } }
        }
        val meta = LinkedHashMap<String, String>()
        val app = root.getElementsByTagName("application").item(0) as? Element
        app?.getElementsByTagName("meta-data")?.let { list ->
            for (i in 0 until list.length) {
                val el = list.item(i) as Element
                val name = el.getAttribute("android:name")
                val value = el.getAttribute("android:value")
                if (name.isNotEmpty()) meta[name] = value
            }
        }
        return Manifest(
            packageName = root.getAttribute("package"),
            versionName = root.getAttribute("android:versionName"),
            versionCode = root.getAttribute("android:versionCode").toIntOrNull() ?: 0,
            features = features,
            metaData = meta,
        )
    }

    /** dex -> class conversion, as Suwayomi does it (PackageTools.dex2jar). */
    private fun convertApk(apk: File, manifest: Manifest): File {
        val outDir = File(TachiRuntime.application.cacheDir, "extensions").also { it.mkdirs() }
        val jar = File(outDir, "${manifest.packageName}-${manifest.versionCode}.jar")
        if (jar.isFile && jar.lastModified() >= apk.lastModified()) return jar
        TachiLog.i("tachi", "converting ${apk.name} with dex2jar")
        val handler = BaksmaliBaseDexExceptionHandler()
        val reader = MultiDexFileReader.open(apk.readBytes())
        Dex2jar.from(reader)
            .withExceptionHandler(handler)
            .reUseReg(false)
            .topoLogicalSort()
            .skipDebug(true)
            .optimizeSynchronized(false)
            .printIR(false)
            .noCode(false)
            .skipExceptions(false)
            .dontSanitizeNames(true)
            .computeFrames(true)
            .to(jar.toPath())
        if (handler.hasException()) {
            TachiLog.w("tachi", "dex2jar reported errors converting ${apk.name}; some classes may be unusable")
        }
        return jar
    }
}
