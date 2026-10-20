package dev.tachi.host.compat

import android.content.SharedPreferences
import dev.tachi.host.TachiLog
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import java.io.File
import java.util.concurrent.CopyOnWriteArraySet

/**
 * SharedPreferences persisted as a JSON object: `{"key": {"t": "s", "v": "..."}}`.
 * Types are tagged so numeric kinds round-trip exactly like Android's XML store.
 */
class FileSharedPreferences(private val file: File) : SharedPreferences {
    private val json = Json { prettyPrint = true }
    private val values = LinkedHashMap<String, Any>()
    private val listeners = CopyOnWriteArraySet<SharedPreferences.OnSharedPreferenceChangeListener>()

    init {
        load()
    }

    @Synchronized
    override fun getAll(): MutableMap<String, *> = LinkedHashMap(values)

    /** Reads the file again, for values written by someone else (a restored backup). */
    @Synchronized
    fun reload() {
        values.clear()
        load()
    }

    @Synchronized
    override fun getString(key: String, defValue: String?): String? = values[key] as? String ?: defValue

    @Synchronized
    @Suppress("UNCHECKED_CAST")
    override fun getStringSet(key: String, defValues: MutableSet<String>?): MutableSet<String>? =
        (values[key] as? Set<String>)?.toMutableSet() ?: defValues

    @Synchronized
    override fun getInt(key: String, defValue: Int): Int = (values[key] as? Number)?.toInt() ?: defValue

    @Synchronized
    override fun getLong(key: String, defValue: Long): Long = (values[key] as? Number)?.toLong() ?: defValue

    @Synchronized
    override fun getFloat(key: String, defValue: Float): Float = (values[key] as? Number)?.toFloat() ?: defValue

    @Synchronized
    override fun getBoolean(key: String, defValue: Boolean): Boolean = values[key] as? Boolean ?: defValue

    @Synchronized
    override fun contains(key: String): Boolean = values.containsKey(key)

    override fun edit(): SharedPreferences.Editor = Editor()

    override fun registerOnSharedPreferenceChangeListener(listener: SharedPreferences.OnSharedPreferenceChangeListener) {
        listeners.add(listener)
    }

    override fun unregisterOnSharedPreferenceChangeListener(listener: SharedPreferences.OnSharedPreferenceChangeListener) {
        listeners.remove(listener)
    }

    private inner class Editor : SharedPreferences.Editor {
        private val modified = LinkedHashMap<String, Any?>() // null = remove
        private var clear = false

        override fun putString(key: String, value: String?) = apply { modified[key] = value }

        override fun putStringSet(key: String, values: MutableSet<String>?) = apply { modified[key] = values?.toSet() }

        override fun putInt(key: String, value: Int) = apply { modified[key] = value }

        override fun putLong(key: String, value: Long) = apply { modified[key] = value }

        override fun putFloat(key: String, value: Float) = apply { modified[key] = value }

        override fun putBoolean(key: String, value: Boolean) = apply { modified[key] = value }

        override fun remove(key: String) = apply { modified[key] = null }

        override fun clear() = apply { clear = true }

        override fun commit(): Boolean {
            val changed = ArrayList<String>()
            synchronized(this@FileSharedPreferences) {
                if (clear) {
                    changed.addAll(values.keys)
                    values.clear()
                }
                for ((k, v) in modified) {
                    if (v == null) {
                        if (values.remove(k) != null) changed.add(k)
                    } else {
                        values[k] = v
                        changed.add(k)
                    }
                }
                persist()
            }
            for (key in changed) {
                for (l in listeners) l.onSharedPreferenceChanged(this@FileSharedPreferences, key)
            }
            return true
        }

        override fun apply() {
            commit()
        }
    }

    private fun persist() {
        try {
            val obj = JsonObject(
                values.mapValues { (_, v) ->
                    when (v) {
                        is String -> JsonObject(mapOf("t" to JsonPrimitive("s"), "v" to JsonPrimitive(v)))
                        is Boolean -> JsonObject(mapOf("t" to JsonPrimitive("b"), "v" to JsonPrimitive(v)))
                        is Int -> JsonObject(mapOf("t" to JsonPrimitive("i"), "v" to JsonPrimitive(v)))
                        is Long -> JsonObject(mapOf("t" to JsonPrimitive("l"), "v" to JsonPrimitive(v)))
                        is Float -> JsonObject(mapOf("t" to JsonPrimitive("f"), "v" to JsonPrimitive(v)))
                        is Set<*> -> JsonObject(
                            mapOf("t" to JsonPrimitive("ss"), "v" to JsonArray(v.map { JsonPrimitive(it.toString()) })),
                        )
                        else -> JsonObject(mapOf("t" to JsonPrimitive("s"), "v" to JsonPrimitive(v.toString())))
                    }
                },
            )
            file.parentFile?.mkdirs()
            val tmp = File(file.parentFile, file.name + ".tmp")
            tmp.writeText(json.encodeToString(JsonElement.serializer(), obj))
            if (!tmp.renameTo(file)) {
                file.delete()
                tmp.renameTo(file)
            }
        } catch (e: Exception) {
            TachiLog.w("tachi", "Failed to persist preferences ${file.name}", e)
        }
    }

    private fun load() {
        if (!file.exists()) return
        try {
            val obj = json.parseToJsonElement(file.readText()).jsonObject
            for ((k, el) in obj) {
                val entry = el.jsonObject
                val v = entry["v"] ?: continue
                val parsed: Any? = when (entry["t"]?.jsonPrimitive?.contentOrNull) {
                    "s" -> v.jsonPrimitive.contentOrNull
                    "b" -> v.jsonPrimitive.booleanOrNull
                    "i" -> v.jsonPrimitive.content.toIntOrNull()
                    "l" -> v.jsonPrimitive.content.toLongOrNull()
                    "f" -> v.jsonPrimitive.content.toFloatOrNull()
                    "ss" -> v.jsonArray.map { it.jsonPrimitive.content }.toSet()
                    else -> null
                }
                if (parsed != null) values[k] = parsed
            }
        } catch (e: Exception) {
            TachiLog.w("tachi", "Failed to load preferences ${file.name}", e)
        }
    }
}
