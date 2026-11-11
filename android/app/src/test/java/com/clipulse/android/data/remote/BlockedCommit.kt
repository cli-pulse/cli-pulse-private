package com.clipulse.android.data.remote

import java.util.concurrent.Callable
import java.util.concurrent.CountDownLatch
import java.util.concurrent.ExecutionException
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.TimeoutException

/**
 * A TokenStore mutator stuck inside `commit()`, as a slow disk leaves it: [write] runs on its
 * own thread and holds the store's lock from the moment its commit starts until [close]. Only
 * that first commit is held; later ones go through.
 */
internal class BlockedCommit(prefs: InMemorySharedPreferences, write: () -> Unit) : AutoCloseable {
    private val writing = CountDownLatch(1)
    private val release = CountDownLatch(1)
    private val thread = Thread { write() }

    init {
        prefs.diskWriteHook = {
            prefs.diskWriteHook = null
            writing.countDown()
            release.await()
        }
        thread.isDaemon = true
        thread.start()
        check(writing.await(5, TimeUnit.SECONDS)) { "the commit never started" }
    }

    override fun close() {
        release.countDown()
        thread.join(5_000)
    }

    companion object {
        /**
         * Runs [block] on a thread of its own, standing in for the main thread, and fails if it
         * has not returned within [seconds]: then it waited for the commit that is held.
         */
        fun <T> returnsWithoutWaiting(what: String, seconds: Long = 2, block: () -> T): T {
            val pool = Executors.newSingleThreadExecutor()
            try {
                return pool.submit(Callable { block() }).get(seconds, TimeUnit.SECONDS)
            } catch (e: TimeoutException) {
                throw AssertionError("$what waited for a commit in progress")
            } catch (e: ExecutionException) {
                throw e.cause ?: e
            } finally {
                pool.shutdown()
            }
        }
    }
}
