package dev.tachi.host

import eu.kanade.tachiyomi.network.await
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicReference
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CompletableDeferred
import okhttp3.Call
import okhttp3.Callback
import okhttp3.OkHttpClient
import okhttp3.Request

object OperationsTest {
    private fun CountDownLatch.waitBounded() = check(await(5, TimeUnit.SECONDS)) { "Operation test timed out" }

    private fun deliveredResponseCancellation() {
        val id = Operations.begin()
        val delivered = CountDownLatch(1)
        val bodyReleased = CountDownLatch(1)
        val done = CountDownLatch(1)
        val failure = AtomicReference<Throwable?>()
        val delegate = OkHttpClient().newCall(Request.Builder().url("http://127.0.0.1/").build())
        val call = object : Call by delegate {
            override fun enqueue(responseCallback: Callback) {
                val response = okhttp3.Response.Builder().request(request()).protocol(okhttp3.Protocol.HTTP_1_1)
                    .code(200).message("OK").body(okhttp3.ResponseBody.EMPTY).build()
                responseCallback.onResponse(this, response)
            }
            override fun cancel() { delegate.cancel(); bodyReleased.countDown() }
        }
        val thread = Thread {
            try {
                Operations.enter(id)
                try {
                    Operations.blocking {
                        call.await().use {
                            delivered.countDown()
                            // Simulates a response-body read after the header continuation completed.
                            bodyReleased.waitBounded()
                        }
                    }
                    error("Delivered response operation ignored cancellation")
                } catch (_: CancellationException) { }
            } catch (t: Throwable) { failure.set(t) }
            finally { Operations.end(id); done.countDown() }
        }
        thread.start()
        try {
            delivered.waitBounded()
            Operations.cancel(id)
            done.waitBounded()
            check(delegate.isCanceled()) { "Delivered HTTP call was no longer tracked" }
        } finally {
            Operations.cancel(id); bodyReleased.countDown(); thread.join(5000)
        }
        failure.get()?.let { throw AssertionError("Response body cancellation failed", it) }
    }

    @JvmStatic fun main(args: Array<String>) {
        val first = Operations.begin()
        val second = Operations.begin()
        val firstStarted = CountDownLatch(1)
        val secondStarted = CountDownLatch(1)
        val firstDone = CountDownLatch(1)
        val secondDone = CountDownLatch(1)
        val releaseSecond = CompletableDeferred<Unit>()
        val failure = AtomicReference<Throwable?>()
        val httpCanceled = AtomicBoolean()
        val delegate = OkHttpClient().newCall(Request.Builder().url("http://127.0.0.1/").build())
        val call = object : Call by delegate {
            override fun enqueue(responseCallback: Callback) { firstStarted.countDown() }
            override fun cancel() { httpCanceled.set(true); delegate.cancel() }
        }
        val a = Thread {
            try {
                Operations.enter(first)
                try {
                    Operations.blocking { call.await().close() }
                    error("Canceled operation completed successfully")
                } catch (_: CancellationException) { }
            } catch (t: Throwable) { failure.set(t) }
            finally { Operations.end(first); firstDone.countDown() }
        }
        val b = Thread {
            try {
                Operations.enter(second)
                Operations.blocking { secondStarted.countDown(); releaseSecond.await() }
            } catch (t: Throwable) { failure.set(t) }
            finally { Operations.end(second); secondDone.countDown() }
        }
        a.start(); b.start()
        try {
            firstStarted.waitBounded(); secondStarted.waitBounded()
            Operations.cancel(first)
            firstDone.waitBounded()
            check(httpCanceled.get()) { "Coroutine cancellation did not cancel its HTTP call" }
            check(secondDone.count == 1L) { "Canceling one operation canceled another" }
            Operations.cancel(first) // A completed ID must not affect another operation.
            releaseSecond.complete(Unit)
            secondDone.waitBounded()
        } finally {
            Operations.cancel(first); Operations.cancel(second)
            a.join(5000); b.join(5000)
        }
        failure.get()?.let { throw AssertionError("Operation worker failed", it) }
        val early = Operations.begin()
        Operations.cancel(early)
        Operations.enter(early)
        var ran = false
        try {
            try {
                Operations.blocking { ran = true }
                error("Pre-start cancellation was ignored")
            } catch (_: CancellationException) { }
        } finally { Operations.end(early) }
        check(!ran)
        deliveredResponseCancellation()
        check(Operations.activeCount == 0) { "Operation registry leaked entries" }
        check(Operations.blocking { 42 } == 42) // end cleared the thread-local context.
        println("PASS: targeted, pre-start, HTTP and delivered-response cancellation; registry and thread-local cleanup")
    }
}
