package com.clipulse.android.data.session

import com.clipulse.android.data.local.CachedDashboard
import com.clipulse.android.data.local.FakeCacheDao
import com.clipulse.android.data.remote.ApiError
import com.clipulse.android.data.remote.EndReason
import com.clipulse.android.data.remote.InMemorySharedPreferences
import com.clipulse.android.data.remote.TokenStore
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test
import kotlin.time.Duration.Companion.seconds

/**
 * The teardown that follows an end, its recovery after a process death, and the writer rule
 * (wait for the teardown, then write only for the current session). Real TokenStore, an
 * in-memory DAO, and an app scope on the test scheduler.
 */
@OptIn(ExperimentalCoroutinesApi::class)
class SessionLifecycleTest {

    private val prefs = InMemorySharedPreferences()
    private val store = TokenStore(prefs)
    private val dao = FakeCacheDao()

    private fun TestScope.appScope() = CoroutineScope(SupervisorJob() + StandardTestDispatcher(testScheduler))

    private fun installA(): String = store.installSession("access-A", "refresh-A", "user-A")!!

    private fun assertAllTablesEmpty() {
        for (t in FakeCacheDao.TABLES) assertEquals("table $t", 0, dao.rowCount(t))
    }

    @Test
    fun `startup finishes a teardown that a killed process left pending`() = runTest {
        val a = installA()
        dao.fill("A")
        // The process died right after the credentials went: marker written, nothing deleted.
        store.endIfCurrent(a, EndReason.SessionRefused)
        val scope = appScope()

        SessionLifecycle(store, dao, scope).start()
        runCurrent()

        assertAllTablesEmpty()
        assertNull(store.teardownPending)
        for (t in FakeCacheDao.TABLES) assertEquals(1, dao.calls.count { it == "clear:$t" })
        scope.cancel()
    }

    @Test
    fun `one failing delete does not stop the other five and keeps the marker for the next start`() = runTest {
        val a = installA()
        dao.fill("A")
        store.endIfCurrent(a, EndReason.UserSignedOut)
        dao.failingClears += "providers"
        val scope = appScope()

        SessionLifecycle(store, dao, scope).start()
        runCurrent()

        for (t in FakeCacheDao.TABLES - "providers") assertEquals("table $t", 0, dao.rowCount(t))
        assertEquals(1, dao.rowCount("providers"))
        assertEquals("retained for a retry", a, store.teardownPending)

        // Next process start: the delete works now.
        dao.failingClears.clear()
        SessionLifecycle(store, dao, scope).start()
        runCurrent()
        assertAllTablesEmpty()
        assertNull(store.teardownPending)
        scope.cancel()
    }

    @Test
    fun `an end through the lifecycle empties memory at once and the cache right after`() = runTest {
        val a = installA()
        dao.fill("A")
        val scope = appScope()
        val lifecycle = SessionLifecycle(store, dao, scope)
        var resets = 0
        lifecycle.register(object : SessionScopedState {
            override fun reset() { resets++ }
        })

        val ended = lifecycle.endIfCurrent(a, EndReason.UserSignedOut)

        assertNotNull(ended)
        assertTrue("in-memory rows go before the screen changes", resets >= 1)
        runCurrent()
        assertAllTablesEmpty()
        assertNull(store.teardownPending)
        assertNull("a second end is a no-op", lifecycle.endIfCurrent(a, EndReason.UserSignedOut))
        scope.cancel()
    }

    @Test
    fun `a write runs for the current session and is refused for one that ended`() = runTest {
        installA()
        val ctxA = store.snapshot()!!
        val scope = appScope()
        val lifecycle = SessionLifecycle(store, dao, scope)

        lifecycle.write(ctxA) { dao.saveDashboard(CachedDashboard(json = "A")) }
        assertEquals(listOf("A"), dao.allRows())

        lifecycle.endIfCurrent(ctxA.sessionId, EndReason.UserSignedOut)
        runCurrent()
        var ran = false
        try {
            lifecycle.write(ctxA) { ran = true }
            fail("a write for an ended session must be refused")
        } catch (e: ApiError.SessionSuperseded) {
            // expected
        }
        assertFalse(ran)
        assertTrue(dao.allRows().isEmpty())
        scope.cancel()
    }

    @Test
    fun `the next account's first write waits for the previous account's teardown`() = runTest {
        val a = installA()
        dao.fill("A")
        // Ended by the client (no teardown started yet), and B signs in at once.
        store.endIfCurrent(a, EndReason.SessionRefused)
        store.installSession("access-B", "refresh-B", "user-B")
        val ctxB = store.snapshot()!!
        val scope = appScope()
        val lifecycle = SessionLifecycle(store, dao, scope)

        val writer = scope.launch {
            lifecycle.write(ctxB) { dao.saveDashboard(CachedDashboard(json = "B")) }
        }
        runCurrent()
        assertFalse("B's write waits while A's teardown is pending", "B" in dao.allRows())

        lifecycle.runPendingTeardown()
        runCurrent()

        assertTrue(writer.isCompleted)
        assertEquals("exactly B's row; A's are gone and B's was not deleted", listOf("B"), dao.allRows())
        scope.cancel()
    }

    @Test
    fun `a write waits for a teardown that is holding the lock`() = runTest {
        val a = installA()
        dao.fill("A")
        val release = CompletableDeferred<Unit>()
        dao.beforeClear = { table -> if (table == "dashboard") release.await() }
        val scope = appScope()
        val lifecycle = SessionLifecycle(store, dao, scope)

        lifecycle.endIfCurrent(a, EndReason.UserSignedOut)
        runCurrent() // the teardown holds the lock at the barrier
        store.installSession("access-B", "refresh-B", "user-B")
        val ctxB = store.snapshot()!!
        val writer = scope.launch {
            lifecycle.write(ctxB) { dao.saveDashboard(CachedDashboard(json = "B")) }
        }
        runCurrent()
        assertFalse("B" in dao.allRows())

        release.complete(Unit)
        runCurrent()

        assertTrue(writer.isCompleted)
        assertEquals(listOf("B"), dao.allRows())
        assertNull(store.teardownPending)
        scope.cancel()
    }

    @Test
    fun `a writer gives up with TeardownPending when the teardown keeps failing`() = runTest(timeout = 10.seconds) {
        val a = installA()
        dao.fill("A")
        dao.failingClears += FakeCacheDao.TABLES
        val scope = appScope()
        val lifecycle = SessionLifecycle(store, dao, scope)
        var resets = 0
        lifecycle.register(object : SessionScopedState {
            override fun reset() { resets++ }
        })
        lifecycle.endIfCurrent(a, EndReason.UserSignedOut)
        runCurrent()
        assertEquals(a, store.teardownPending)
        store.installSession("access-B", "refresh-B", "user-B")
        val ctxB = store.snapshot()!!
        val resetsBefore = resets

        var ran = false
        try {
            // Virtual time: the bounded wait elapses at once instead of hanging the screen.
            lifecycle.write(ctxB) { ran = true }
            fail("expected TeardownPending")
        } catch (e: ApiError.TeardownPending) {
            // expected
        }
        assertFalse(ran)
        assertTrue("the in-memory rows are emptied on the timeout", resets > resetsBefore)
        scope.cancel()
    }
}
