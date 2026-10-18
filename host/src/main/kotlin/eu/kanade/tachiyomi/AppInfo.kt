package eu.kanade.tachiyomi

import dev.tachi.host.TachiRuntime

/**
 * Identity the host presents to extensions. Some extensions gate features on
 * the app version, so the values are configurable at runtime init.
 */
@Suppress("Unused")
object AppInfo {
    fun getVersionCode(): Int = TachiRuntime.config.appVersionCode

    fun getVersionName(): String = TachiRuntime.config.appVersionName
}
