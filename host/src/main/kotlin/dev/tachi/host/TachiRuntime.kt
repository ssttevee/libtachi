package dev.tachi.host

import android.app.Application
import android.content.Context
import dev.tachi.host.compat.TachiContext
import eu.kanade.tachiyomi.network.JavaScriptEngine
import eu.kanade.tachiyomi.network.JsEngine
import eu.kanade.tachiyomi.network.NetworkHelper
import eu.kanade.tachiyomi.network.interceptor.CloudflareSolver
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import uy.kohesive.injekt.Injekt
import uy.kohesive.injekt.api.addSingleton
import uy.kohesive.injekt.api.addSingletonFactory
import java.io.File

@Serializable
data class RuntimeConfig(
    /** Root directory for everything the host persists (preferences, cookies, converted APKs). */
    val dataDir: String,
    /** Cache directory; defaults to `<dataDir>/cache`. */
    val cacheDir: String? = null,
    val userAgent: String =
        "Mozilla/5.0 (Linux; Android 10; K) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/140.0.0.0 Mobile Safari/537.36",
    /** Version the host reports through eu.kanade.tachiyomi.AppInfo. */
    val appVersionName: String = "0.20.1",
    val appVersionCode: Int = 137,
    /** Package name reported by Context.getPackageName(). */
    val packageName: String = "app.mihon",
    val verbose: Boolean = false,
    /** True when the native side registered NativeHooks.log. */
    val nativeLog: Boolean = false,
)

/** Process-wide state of the host: configuration, the fake Application, and DI wiring. */
object TachiRuntime {
    @Volatile
    private var _config: RuntimeConfig? = null

    val config: RuntimeConfig
        get() = _config ?: error("TachiRuntime.init has not been called")

    lateinit var application: Application
        private set

    lateinit var network: NetworkHelper
        private set

    /** Optional JavaScript engine supplied by the embedder. */
    @Volatile
    var jsEngine: JsEngine? = null

    /** Optional Cloudflare challenge solver supplied by the embedder. */
    @Volatile
    var cloudflareSolver: CloudflareSolver? = null

    val json: Json = Json {
        ignoreUnknownKeys = true
        explicitNulls = false
        encodeDefaults = true
    }

    @Synchronized
    fun init(config: RuntimeConfig) {
        if (_config != null) {
            TachiLog.w("tachi", "TachiRuntime.init called twice; keeping the first configuration")
            return
        }
        TachiLog.minLevel = if (config.verbose) TachiLog.VERBOSE else TachiLog.INFO
        TachiLog.nativeSink = config.nativeLog

        val dataDir = File(config.dataDir).absoluteFile
        val cacheDir = config.cacheDir?.let { File(it).absoluteFile } ?: File(dataDir, "cache")
        dataDir.mkdirs()
        cacheDir.mkdirs()

        val context = TachiContext(dataDir, cacheDir, config.packageName)
        application = Application().also { it.attach(context) }
        _config = config

        // Extensions reach host services through Injekt (uy.kohesive.injekt.Injekt.get<T>()).
        Injekt.addSingleton<Application>(application)
        Injekt.addSingleton<Context>(application)
        Injekt.addSingletonFactory { NetworkHelper(application) }
        Injekt.addSingletonFactory { JavaScriptEngine(application) }
        Injekt.addSingleton<Json>(json)

        network = Injekt.getInstance(NetworkHelper::class.java)
        System.setProperty("http.agent", config.userAgent)
        application.onCreate()
        TachiLog.i("tachi", "host runtime initialised (data=$dataDir)")
    }

    val isInitialised: Boolean get() = _config != null
}
