package dev.tachi.host

import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicLong
import kotlin.coroutines.EmptyCoroutineContext
import kotlinx.coroutines.CompletableJob
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withContext

/** One parent job per native invocation, published before its execution can start. */
internal object Operations {
    private data class Entry(val id: Long, val job: CompletableJob)
    private val nextId = AtomicLong()
    private val entries = ConcurrentHashMap<Long, Entry>()
    private val current = ThreadLocal<Entry>()

    fun begin(): Long {
        val id = nextId.incrementAndGet()
        check(id > 0) { "Operation IDs exhausted" }
        entries[id] = Entry(id, Job())
        return id
    }

    fun enter(id: Long) {
        check(current.get() == null) { "Native operation already entered" }
        current.set(checkNotNull(entries[id]) { "Unknown operation $id" })
    }

    fun cancel(id: Long) {
        entries[id]?.job?.cancel()
    }

    fun end(id: Long) {
        if (current.get()?.id == id) current.remove()
        entries.remove(id)?.job?.complete()
    }

    // Legacy callers without an operation keep their existing coroutine behavior.
    fun <T> blocking(block: suspend CoroutineScope.() -> T): T =
        runBlocking(current.get()?.job ?: EmptyCoroutineContext) {
            withContext(Dispatchers.IO, block)
        }

    internal val activeCount: Int get() = entries.size
}
