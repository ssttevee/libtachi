package dev.tachi.host.compat

import android.content.Context
import android.content.SharedPreferences
import java.io.File
import java.util.concurrent.ConcurrentHashMap

/** The base Context behind the host's Application: maps Android directories onto the configured data dir. */
class TachiContext(
    private val dataDir: File,
    private val cacheDir: File,
    private val packageName: String,
) : Context() {
    private val filesDir = File(dataDir, "files").also { it.mkdirs() }
    private val prefsDir = File(dataDir, "prefs").also { it.mkdirs() }
    private val prefs = ConcurrentHashMap<String, SharedPreferences>()

    override fun getSharedPreferences(name: String, mode: Int): SharedPreferences =
        prefs.getOrPut(name) { FileSharedPreferences(File(prefsDir, "${sanitize(name)}.json")) }

    override fun getCacheDir(): File = cacheDir

    override fun getFilesDir(): File = filesDir

    override fun getDataDir(): File = dataDir

    override fun getPackageName(): String = packageName

    override fun getApplicationContext(): Context = this

    override fun deleteSharedPreferences(name: String): Boolean {
        prefs.remove(name)
        return File(prefsDir, "${sanitize(name)}.json").delete()
    }

    private fun sanitize(name: String): String = name.replace(Regex("[^A-Za-z0-9._-]"), "_")
}
