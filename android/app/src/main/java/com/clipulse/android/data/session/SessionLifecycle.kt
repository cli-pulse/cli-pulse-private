package com.clipulse.android.data.session

import android.util.Log
import com.clipulse.android.data.local.CacheDao
import com.clipulse.android.data.remote.ApiError
import com.clipulse.android.data.remote.EndReason
import com.clipulse.android.data.remote.EndedSession
import com.clipulse.android.data.remote.SessionContext
import com.clipulse.android.data.remote.TokenStore
import com.clipulse.android.di.ApplicationScope
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
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
 * The one coordinator of a session's life on this device. ONE mutex serialises:
 *
 *  - every session transition: [install], [enterDemoMode], [endIfCurrent], [endCurrent];
 *  - the teardown of an ended session's data (empty the in-memory rows, delete the six Room
 *    tables, clear the marker), which runs INSIDE the transition that ended it;
 *  - every cache/flow write and hydration ([write]).
 *
 * So a write or hydration either finishes before an end (and the end then empties what it
 * wrote) or starts after it (and is refused because its session is gone); a reset can only
 * ever empty rows of the session that just ended; and the next account's first write cannot
 * begin until the previous account's deletion has finished.
 *
 * Durability: the transition is committed (credentials wiped, marker written) before any
 * deletion, and the cleared marker is committed before the lock is released to writers. If a
 * commit or a delete fails, the marker stays, writers are refused ([ApiError.TeardownPending]),
 * and a coalesced retry with backoff runs in this process; [start] also finishes whatever a
 * previous process left. Any commit of the store that fails (a token rotation included) asks
 * for that retry too, so it is written again without waiting for a later write.
 *
 * Once a transition has committed, its teardown runs to the end even if the caller is
 * cancelled (a screen that the end itself closes, for instance), and any way out of it short of
 * "nothing pending" schedules the retry.
 */
@Singleton
class SessionLifecycle internal constructor(
    private val tokenStore: TokenStore,
    private val cache: CacheDao,
    private val appScope: CoroutineScope,
    private val dispatcher: CoroutineDispatcher,
) {
    @Inject
    constructor(
        tokenStore: TokenStore,
        cache: CacheDao,
        @ApplicationScope appScope: CoroutineScope,
    ) : this(tokenStore, cache, appScope, Dispatchers.IO)

    private val stateMutex = Mutex()
    private val scopedStates = CopyOnWriteArrayList<SessionScopedState>()
    private val started = AtomicBoolean(false)

    /** One deadline for a writer: from its call to holding the lock. */
    internal var writeTimeoutMillis: Long = WRITE_TIMEOUT_MS
    internal var retryBaseMillis: Long = RETRY_BASE_MS
    internal var retryMaxMillis: Long = RETRY_MAX_MS

    /** Tests only: runs inside [write]'s deadline right after it took the lock. */
    internal var afterWriteLockAcquired: (suspend () -> Unit)? = null

    private val retryLock = Any()
    private var retryJob: Job? = null

    /** Retries since the last success; the next one waits retryBaseMillis * 2^n, capped. */
    private var retryAttempts = 0

    init {
        tokenStore.onCommitFailed = { scheduleRetry() }
    }

    fun register(state: SessionScopedState) {
        scopedStates += state
    }

    /**
     * From `Application.onCreate`: finishes whatever a previous process left (a marker
     * written before a deletion that never ran), and, on the first start of this version
     * with no session, deletes cache rows an older version may have left after a sign-out.
     */
    fun start() {
        if (!started.compareAndSet(false, true)) return
        appScope.launch {
            locked {
                tokenStore.markLegacyCacheForTeardownIfNeeded()
                settleLocked()
            }
        }
    }

    // ── Transitions ──────────────────────────────────────────────────────

    /**
     * Installs a signed-in session if [attempt] is still the current sign-in generation
     * (null: no check). A session it replaces is torn down in the same step. Null: overtaken.
     * [receivedAtMillis] is when the answer carrying the tokens arrived, not when this got
     * the lock: the token's lifetime runs from then.
     */
    suspend fun install(
        accessToken: String?,
        refreshToken: String?,
        userId: String?,
        userName: String? = null,
        userEmail: String? = null,
        attempt: Long? = null,
        receivedAtMillis: Long = System.currentTimeMillis(),
    ): String? = locked {
        val id = tokenStore.installSession(
            accessToken = accessToken,
            refreshToken = refreshToken,
            userId = userId,
            userName = userName,
            userEmail = userEmail,
            attempt = attempt,
            receivedAtMillis = receivedAtMillis,
        )
        if (id != null) settleLocked()
        id
    }

    /** Demo mode, with its synthetic session id; abandons every sign-in still out. */
    suspend fun enterDemoMode(): String = locked {
        val id = tokenStore.enterDemoMode()
        settleLocked()
        id
    }

    /**
     * Ends [sessionId] if it is still current and deletes its on-device data before
     * returning. Null when that session already ended or was replaced: nothing changes then.
     */
    suspend fun endIfCurrent(sessionId: String, reason: EndReason): EndedSession? = locked {
        val ended = tokenStore.endIfCurrent(sessionId, reason)
        if (ended != null) settleLocked()
        ended
    }

    /** [endIfCurrent] for whatever session is current. */
    suspend fun endCurrent(reason: EndReason): EndedSession? = locked {
        val ended = tokenStore.endCurrent(reason)
        if (ended != null) settleLocked()
        ended
    }

    /** Runs any pending teardown now. True when nothing is left pending. */
    suspend fun runPendingTeardown(): Boolean = locked { settleLocked() }

    // ── Writes ───────────────────────────────────────────────────────────

    /**
     * Runs [block] (which sets the flows and writes Room) for [ctx]'s session, or not at all:
     * [ApiError.SessionSuperseded] if that session is not the current one (checked at once,
     * and again under the lock); [ApiError.TeardownPending] if the lock is not free within one
     * overall deadline, or a previous session's data has not been deleted yet. Nothing is
     * reset here: only transitions empty the in-memory rows, under the lock.
     *
     * Ownership of the lock is recorded the moment `lock()` returns, inside the deadline, and the
     * `finally` that releases it is entered before the deadline starts. A deadline can fire after
     * `lock()` returned but before the timeout block did; `withTimeoutOrNull` then returns null
     * although the lock is held. So two things are tracked apart: whether the lock is held
     * (`owned`, which decides the unlock) and whether the deadline was met (the block's result,
     * which decides the write). A writer whose deadline passed writes nothing, lock or not.
     */
    suspend fun <T> write(ctx: SessionContext, block: suspend () -> T): T {
        if (tokenStore.sessionId != ctx.sessionId) throw ApiError.SessionSuperseded
        var owned = false
        try {
            val inTime = withTimeoutOrNull(writeTimeoutMillis) {
                stateMutex.lock()
                owned = true
                afterWriteLockAcquired?.invoke()
                true
            } == true
            if (!inTime) throw ApiError.TeardownPending
            if (tokenStore.sessionId != ctx.sessionId) throw ApiError.SessionSuperseded
            if (tokenStore.teardownPending != null || !tokenStore.isDurable) {
                scheduleRetry()
                throw ApiError.TeardownPending
            }
            return block()
        } finally {
            if (owned) stateMutex.unlock()
        }
    }

    // ── Internals ────────────────────────────────────────────────────────

    private suspend fun <T> locked(block: suspend () -> T): T =
        withContext(dispatcher) { stateMutex.withLock { block() } }

    /**
     * With the lock held: makes the stored session state durable, then deletes the data of
     * the session the marker names. True when nothing is left pending; otherwise a retry is
     * scheduled and writers stay refused.
     *
     * The transition before it has already committed, so this does not stop when its caller
     * is cancelled (NonCancellable), and every exit short of "settled", an exception included,
     * schedules the retry (finally).
     */
    private suspend fun settleLocked(): Boolean = withContext(NonCancellable) {
        var settled = false
        try {
            settled = settleOnce()
            settled
        } finally {
            if (settled) resetRetry() else scheduleRetry()
        }
    }

    private suspend fun settleOnce(): Boolean {
        // The transition is not on disk: deleting now could leave Room ahead of the
        // preferences after a process death. Keep the barrier and retry.
        if (!tokenStore.isDurable && !tokenStore.recommit()) return false
        val marker = tokenStore.teardownPending ?: return true
        resetScopedStates()
        var allDeleted = true
        for (table in CacheTable.entries) {
            try {
                delete(table)
            } catch (e: Exception) {
                // CancellationException included: nothing here is cancellable from outside
                // (NonCancellable), so one can only be the DAO's own failure. Retried later.
                allDeleted = false
                logTeardownFailure(table)
            }
        }
        return allDeleted && tokenStore.clearPendingIfEquals(marker)
    }

    /** A coalesced retry of [runPendingTeardown], with doubling backoff from [retryBaseMillis]. */
    private fun scheduleRetry() {
        synchronized(retryLock) {
            if (retryJob?.isActive == true) return
            // At least 1 ms: a base or cap of zero must back off, not spin at one instant.
            val wait = maxOf(1L, minOf(retryBaseMillis shl minOf(retryAttempts, MAX_BACKOFF_SHIFT), retryMaxMillis))
            retryAttempts++
            retryJob = appScope.launch {
                delay(wait)
                synchronized(retryLock) { retryJob = null }
                runPendingTeardown()
            }
        }
    }

    private fun resetRetry() {
        synchronized(retryLock) { retryAttempts = 0 }
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
        const val WRITE_TIMEOUT_MS = 5_000L
        const val RETRY_BASE_MS = 5_000L
        const val RETRY_MAX_MS = 5 * 60_000L
        const val MAX_BACKOFF_SHIFT = 16
    }
}
