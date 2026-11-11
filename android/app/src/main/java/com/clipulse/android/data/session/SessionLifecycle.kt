package com.clipulse.android.data.session

import android.util.Log
import com.clipulse.android.data.local.CacheDao
import com.clipulse.android.data.remote.ApiError
import com.clipulse.android.data.remote.EndReason
import com.clipulse.android.data.remote.EndedSession
import com.clipulse.android.data.remote.SessionContext
import com.clipulse.android.data.remote.TokenStore
import com.clipulse.android.di.ApplicationScope
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withTimeoutOrNull
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.atomic.AtomicBoolean
import javax.inject.Inject
import javax.inject.Singleton

/** In-memory state that belongs to one session, emptied when that session ends. */
interface SessionScopedState {
    fun reset()
}

/**
 * What happens on this device when a session ends, and the rule every session-owned write
 * follows so it can never land after (or on top of) that end.
 *
 * Ending is [TokenStore.endIfCurrent]: credentials gone and a durable teardown marker
 * written in one transaction. The teardown that marker stands for, deleting the six Room
 * tables and emptying the in-memory rows, runs here: right after an end, whenever the
 * marker changes, and at every process start ([start]), so a process killed between the
 * two finishes the job next time.
 *
 * One [stateMutex] covers teardown, cache hydration and every cache/flow write. A writer
 * ([write]) waits until no teardown is pending, then, under the lock, requires that its
 * session is still current. So the next account's first write waits for the previous
 * account's teardown, and a delayed teardown can never delete the next account's rows.
 */
@Singleton
class SessionLifecycle @Inject constructor(
    private val tokenStore: TokenStore,
    private val cache: CacheDao,
    @ApplicationScope private val appScope: CoroutineScope,
) {
    private val stateMutex = Mutex()
    private val scopedStates = CopyOnWriteArrayList<SessionScopedState>()
    private val started = AtomicBoolean(false)

    /** How long a writer waits for a pending teardown before giving up with [ApiError.TeardownPending]. */
    internal var teardownWaitMillis: Long = TEARDOWN_WAIT_MS

    fun register(state: SessionScopedState) {
        scopedStates += state
    }

    /**
     * From `Application.onCreate`: runs any teardown a previous process left pending, then
     * again every time a new marker appears (a session ended in the background, by the client
     * or the Worker, with no screen open). Running a teardown twice is harmless.
     */
    fun start() {
        if (!started.compareAndSet(false, true)) return
        appScope.launch {
            tokenStore.state
                .map { it.teardownPending }
                .distinctUntilChanged()
                .collect { marker -> if (marker != null) runPendingTeardown() }
        }
    }

    /**
     * Ends [sessionId] if it is still current ([TokenStore.endIfCurrent]), empties the
     * in-memory rows at once and starts the teardown. Null when that session already ended
     * or was replaced: nothing changes then.
     */
    fun endIfCurrent(sessionId: String, reason: EndReason): EndedSession? =
        tokenStore.endIfCurrent(sessionId, reason)?.also { afterEnd() }

    /** [endIfCurrent] for whatever session is current, read and ended under one lock. */
    fun endCurrent(reason: EndReason): EndedSession? =
        tokenStore.endCurrent(reason)?.also { afterEnd() }

    private fun afterEnd() {
        resetScopedStates()
        appScope.launch { runPendingTeardown() }
    }

    /**
     * Deletes everything the ended session left on this device. Each table is deleted on its
     * own, so one failure does not keep the other five; the marker is cleared only when all
     * six went, and only if it still names the session this run started with. Otherwise it
     * stays and the next start (or the next end) retries. Returns true when nothing is left
     * pending from this run.
     */
    suspend fun runPendingTeardown(): Boolean = stateMutex.withLock {
        val marker = tokenStore.teardownPending ?: return@withLock true
        resetScopedStates()
        var allDeleted = true
        for (table in CacheTable.entries) {
            try {
                delete(table)
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                allDeleted = false
                logTeardownFailure(table)
            }
        }
        if (allDeleted) tokenStore.clearPendingIfEquals(marker)
        allDeleted
    }

    /**
     * Runs [block] (which sets the flows and writes Room) for [ctx]'s session, or not at all.
     *
     * Waits, at most [teardownWaitMillis], until no teardown is pending; on timeout empties
     * the in-memory rows, skips the write and throws [ApiError.TeardownPending] (a failing
     * Room delete must never hang a screen; the next start or end retries the teardown).
     * Then, under [stateMutex], throws [ApiError.SessionSuperseded] unless [ctx] is still the
     * current session.
     */
    suspend fun <T> write(ctx: SessionContext, block: suspend () -> T): T {
        while (true) {
            awaitNoTeardown()
            stateMutex.lock()
            try {
                val state = tokenStore.state.value
                // A newer end slipped in between the wait and the lock: wait for it too.
                if (state.teardownPending != null) continue
                if (state.sessionId != ctx.sessionId) throw ApiError.SessionSuperseded
                return block()
            } finally {
                stateMutex.unlock()
            }
        }
    }

    private suspend fun awaitNoTeardown() {
        if (tokenStore.state.value.teardownPending == null) return
        val cleared = withTimeoutOrNull(teardownWaitMillis) {
            tokenStore.state.first { it.teardownPending == null }
        }
        if (cleared == null) {
            resetScopedStates()
            throw ApiError.TeardownPending
        }
    }

    private fun resetScopedStates() {
        for (state in scopedStates) {
            try {
                state.reset()
            } catch (e: Exception) {
                // An in-memory reset has nothing to fail on; never let one block the deletes.
            }
        }
    }

    private suspend fun delete(table: CacheTable) {
        when (table) {
            CacheTable.Dashboard -> cache.clearDashboard()
            CacheTable.Providers -> cache.clearProviders()
            CacheTable.Sessions -> cache.clearSessions()
            CacheTable.Alerts -> cache.clearAlerts()
            CacheTable.Devices -> cache.clearDevices()
            CacheTable.DailyUsage -> cache.clearDailyUsage()
        }
    }

    private fun logTeardownFailure(table: CacheTable) {
        // The table's name only. android.util.Log is not available in JVM unit tests.
        runCatching { Log.w(TAG, "Session teardown: deleting a cache table failed: " + table.name) }
    }

    internal enum class CacheTable { Dashboard, Providers, Sessions, Alerts, Devices, DailyUsage }

    private companion object {
        const val TAG = "SessionLifecycle"
        const val TEARDOWN_WAIT_MS = 5_000L
    }
}
