package dev.tachi.host

import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicLong
import kotlin.coroutines.AbstractCoroutineContextElement
import kotlin.coroutines.CoroutineContext
import kotlin.coroutines.EmptyCoroutineContext
import kotlinx.coroutines.CompletableJob
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.runBlocking
import okhttp3.Call
import kotlinx.coroutines.withContext

/** One parent job per native invocation, published before its execution can start. */
internal object Operations {
    private class Entry(val id: Long, val job: CompletableJob) : AbstractCoroutineContextElement(Key) {
        companion object Key : CoroutineContext.Key<Entry>
        val calls = ConcurrentHashMap.newKeySet<Call>()
    }
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
        val entry = entries[id] ?: return
        entry.job.cancel()
        // A continuation may already have delivered headers while its response
        // body is still blocking. Keep its Call cancelable until the operation ends.
        for (call in entry.calls) call.cancel()
    }

    fun end(id: Long) {
        if (current.get()?.id == id) current.remove()
        entries.remove(id)?.job?.complete()
    }

    suspend fun track(call: Call) {
        val entry = currentCoroutineContext()[Entry] ?: return
        entry.calls.add(call)
        // Covers cancellation racing registration, including after the cancel loop.
        if (!entry.job.isActive) call.cancel()
    }

    // Legacy callers without an operation keep their existing coroutine behavior.
    fun <T> blocking(block: suspend CoroutineScope.() -> T): T {
        val entry = current.get()
        val context = if (entry == null) EmptyCoroutineContext else entry.job + entry
        return runBlocking(context) { withContext(Dispatchers.IO, block) }
    }

    internal val activeCount: Int get() = entries.size
}
