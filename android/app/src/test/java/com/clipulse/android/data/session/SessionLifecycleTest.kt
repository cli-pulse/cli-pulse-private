package com.clipulse.android.data.session

import com.clipulse.android.data.DemoDataProvider
import com.clipulse.android.data.local.CachedDashboard
import com.clipulse.android.data.local.FakeCacheDao
import com.clipulse.android.data.remote.ApiError
import com.clipulse.android.data.remote.EndReason
import com.clipulse.android.data.remote.InMemorySharedPreferences
import com.clipulse.android.data.remote.SupabaseClient
import com.clipulse.android.data.remote.TestJwt
import com.clipulse.android.data.remote.TokenStore
import com.clipulse.android.data.repository.DashboardRepository
import io.mockk.coEvery
import io.mockk.mockk
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.async
import kotlinx.coroutines.cancel
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.currentTime
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import okhttp3.OkHttpClient
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test
import kotlin.time.Duration.Companion.seconds

/**
 * The coordinator: transitions, teardown, hydration and writes under one lock; durable
 * ordering between the preferences and Room; recovery after a process death and retry in the
 * same process. Real TokenStore over a preferences double with separate memory and disk
 * layers, an in-memory DAO, everything on the test scheduler.
 */
/** A scope on the test scheduler that runTest cancels at the end of the test, pass or fail. */
@OptIn(ExperimentalCoroutinesApi::class)
private fun TestScope.childScope(): CoroutineScope =
    CoroutineScope(backgroundScope.coroutineContext + SupervisorJob(backgroundScope.coroutineContext[Job]))

@OptIn(ExperimentalCoroutinesApi::class)
class SessionLifecycleTest {

    /**
     * A store, an in-memory cache, a coordinator and a repository over a mocked client. The
     * coordinator's scope is a child of runTest's background scope, so a retry it scheduled is
     * cancelled when the test ends, even when an assertion failed first (otherwise virtual
     * time would run a teardown that keeps failing forever).
     */
    private class Env(testScope: TestScope, val prefs: InMemorySharedPreferences = InMemorySharedPreferences()) {
        val store = TokenStore(prefs)
        val dao = FakeCacheDao()
        val scope = testScope.childScope()
        val lifecycle = SessionLifecycle(store, dao, scope, StandardTestDispatcher(testScope.testScheduler))
        val supabase = mockk<SupabaseClient>(relaxed = true)
        val repo = DashboardRepository(supabase, dao, store, lifecycle)

        fun installA(): String = store.installSession("access-A", "refresh-A", "user-A")!!
        fun allTablesEmpty() = FakeCacheDao.TABLES.all { dao.rowCount(it) == 0 }
    }

    private class Probe : SessionScopedState {
        val rows = MutableStateFlow<String?>(null)
        var resets = 0
        override fun reset() {
            resets++
            rows.value = null
        }
    }

    // ── recovery ────────────────────────────────────────

    @Test
    fun `startup finishes a teardown that a killed process left pending`() = runTest {
        val before = Env(this)
        val a = before.installA()
        before.dao.fill("A")
        // The process died right after the end was committed, before any deletion ran.
        before.store.endIfCurrent(a, EndReason.SessionRefused)

        val revived = TokenStore(before.prefs.restart())
        assertEquals("the marker reached disk with the end", a, revived.teardownPending)
        val scope = childScope()
        SessionLifecycle(revived, before.dao, scope, StandardTestDispatcher(testScheduler)).start()
        runCurrent()

        assertTrue(before.allTablesEmpty())
        assertNull(revived.teardownPending)
        for (t in FakeCacheDao.TABLES) assertEquals(1, before.dao.calls.count { it == "clear:$t" })
        scope.cancel()
    }

    @Test
    fun `the first start of this version deletes an older version's leftover cache when no one is signed in`() = runTest {
        val env = Env(this)
        env.dao.fill("old")

        env.lifecycle.start()
        runCurrent()

        assertTrue(env.allTablesEmpty())
        assertNull(env.store.teardownPending)
        env.scope.cancel()
    }

    @Test
    fun `the first start of this version leaves a signed-in session's cache alone`() = runTest {
        val env = Env(this)
        env.installA()
        env.dao.fill("A")

        env.lifecycle.start()
        runCurrent()

        assertEquals(6, FakeCacheDao.TABLES.sumOf { env.dao.rowCount(it) })
        env.scope.cancel()
    }

    @Test
    fun `one failing delete does not stop the other five and keeps the marker`() = runTest {
        val env = Env(this)
        val a = env.installA()
        env.dao.fill("A")
        env.dao.failingClears += "providers"

        env.lifecycle.endIfCurrent(a, EndReason.UserSignedOut)

        for (t in FakeCacheDao.TABLES - "providers") assertEquals("table $t", 0, env.dao.rowCount(t))
        assertEquals(1, env.dao.rowCount("providers"))
        assertEquals("retained for a retry", a, env.store.teardownPending)
        env.scope.cancel()
    }

    @Test
    fun `a failed teardown is retried in the same process until it succeeds`() = runTest {
        val env = Env(this)
        val a = env.installA()
        env.dao.fill("A")
        env.dao.failingClears += FakeCacheDao.TABLES
        env.lifecycle.endIfCurrent(a, EndReason.UserSignedOut)
        assertEquals(a, env.store.teardownPending)

        // Still failing at the first retry: it backs off and tries again.
        advanceTimeBy(env.lifecycle.retryBaseMillis + 1)
        runCurrent()
        assertEquals(a, env.store.teardownPending)

        // Room recovers; no restart: the coordinator's own retry finishes the job.
        env.dao.failingClears.clear()
        advanceTimeBy(env.lifecycle.retryMaxMillis + 1)
        runCurrent()
        assertTrue(env.allTablesEmpty())
        assertNull(env.store.teardownPending)
        env.scope.cancel()
    }

    // ── transitions ─────────────────────────────────────

    @Test
    fun `an end empties memory and deletes the cache before it returns`() = runTest {
        val env = Env(this)
        val a = env.installA()
        env.dao.fill("A")
        val probe = Probe().also { env.lifecycle.register(it) }
        probe.rows.value = "A"

        assertNotNull(env.lifecycle.endIfCurrent(a, EndReason.UserSignedOut))

        assertNull(probe.rows.value)
        assertTrue(env.allTablesEmpty())
        assertNull(env.store.teardownPending)
        assertNull("a second end is a no-op", env.lifecycle.endIfCurrent(a, EndReason.UserSignedOut))
        env.scope.cancel()
    }

    @Test
    fun `an end waits for a hydration in progress, then empties what it published`() = runTest {
        val env = Env(this)
        coEvery { env.supabase.dashboard(any()) } returns DemoDataProvider.dashboard()
        val a = env.installA()
        env.repo.refreshDashboard() // A's dashboard is in Room now
        assertTrue("A's row is cached", env.dao.allRows().isNotEmpty())

        // A's hydration has passed the writer's check and is suspended inside Room.
        val readGate = CompletableDeferred<Unit>()
        env.dao.beforeRead = { readGate.await() }
        val hydration = env.scope.launch { env.repo.loadFromCache() }
        runCurrent()
        // A ends and B signs in meanwhile.
        val end = env.scope.async { env.lifecycle.endIfCurrent(a, EndReason.UserSignedOut) }
        val install = env.scope.async { env.lifecycle.install("access-B", "refresh-B", "user-B") }
        runCurrent()
        assertEquals("the end waits for the hydration holding the lock", a, env.store.sessionId)

        readGate.complete(Unit)
        runCurrent()

        assertTrue(hydration.isCompleted)
        assertNotNull(end.await())
        assertEquals(install.await(), env.store.sessionId)
        assertNull("nothing of A's is left for B to see", env.repo.dashboard.value)
        assertTrue(env.dao.allRows().isEmpty())
        env.scope.cancel()
    }

    @Test
    fun `a sign-in waits until the previous session's deletion has finished`() = runTest {
        val env = Env(this)
        val a = env.installA()
        env.dao.fill("A")
        val deleteGate = CompletableDeferred<Unit>()
        env.dao.beforeClear = { table -> if (table == "dashboard") deleteGate.await() }

        val end = env.scope.async { env.lifecycle.endIfCurrent(a, EndReason.UserSignedOut) }
        runCurrent() // the deletion holds the lock at the barrier
        val install = env.scope.async { env.lifecycle.install("access-B", "refresh-B", "user-B") }
        runCurrent()
        assertNull("B is not installed while A's data is being deleted", env.store.sessionId)

        deleteGate.complete(Unit)
        runCurrent()
        val b = install.await()!!
        assertNotNull(end.await())
        env.lifecycle.write(env.store.snapshot()!!) { env.dao.saveDashboard(CachedDashboard(json = "B")) }

        assertEquals(b, env.store.sessionId)
        assertEquals("exactly B's row", listOf("B"), env.dao.allRows())
        env.scope.cancel()
    }

    // ── writes ──────────────────────────────────────────

    @Test
    fun `a write runs for the current session and is refused for one that ended`() = runTest {
        val env = Env(this)
        env.installA()
        val ctxA = env.store.snapshot()!!

        env.lifecycle.write(ctxA) { env.dao.saveDashboard(CachedDashboard(json = "A")) }
        assertEquals(listOf("A"), env.dao.allRows())

        env.lifecycle.endIfCurrent(ctxA.sessionId, EndReason.UserSignedOut)
        var ran = false
        try {
            env.lifecycle.write(ctxA) { ran = true }
            fail("a write for an ended session must be refused")
        } catch (e: ApiError.SessionSuperseded) {
            // expected
        }
        assertFalse(ran)
        assertTrue(env.dao.allRows().isEmpty())
        env.scope.cancel()
    }

    @Test
    fun `a write for a replaced session is refused at once, without waiting for the lock`() = runTest {
        val env = Env(this)
        val a = env.installA()
        val ctxA = env.store.snapshot()!!
        env.lifecycle.endIfCurrent(a, EndReason.UserSignedOut)
        env.lifecycle.install("access-B", "refresh-B", "user-B")
        val ctxB = env.store.snapshot()!!
        val hold = CompletableDeferred<Unit>()
        env.scope.launch { env.lifecycle.write(ctxB) { hold.await() } } // B's long write holds the lock
        runCurrent()

        val start = currentTime
        try {
            env.lifecycle.write(ctxA) {}
            fail("expected SessionSuperseded")
        } catch (e: ApiError.SessionSuperseded) {
            // expected
        }
        assertEquals(0L, currentTime - start)
        hold.complete(Unit)
        env.scope.cancel()
    }

    @Test
    fun `a writer gives up after one overall deadline when the lock is never free`() = runTest(timeout = 10.seconds) {
        val env = Env(this)
        env.installA()
        val ctxA = env.store.snapshot()!!
        val hold = CompletableDeferred<Unit>()
        env.scope.launch { env.lifecycle.write(ctxA) { hold.await() } } // a write that never finishes
        runCurrent()

        val start = currentTime
        try {
            env.lifecycle.write(ctxA) { }
            fail("expected TeardownPending")
        } catch (e: ApiError.TeardownPending) {
            // expected
        }
        assertEquals("one deadline, not more", env.lifecycle.writeTimeoutMillis, currentTime - start)
        hold.complete(Unit)
        env.scope.cancel()
    }

    @Test
    fun `while a previous session's deletion is pending, writes are refused at once`() = runTest {
        val env = Env(this)
        val a = env.installA()
        env.dao.fill("A")
        env.dao.failingClears += FakeCacheDao.TABLES
        env.lifecycle.endIfCurrent(a, EndReason.UserSignedOut)
        env.lifecycle.install("access-B", "refresh-B", "user-B")
        val ctxB = env.store.snapshot()!!
        assertEquals(a, env.store.teardownPending)

        val start = currentTime
        try {
            env.lifecycle.write(ctxB) { env.dao.saveDashboard(CachedDashboard(json = "B")) }
            fail("expected TeardownPending")
        } catch (e: ApiError.TeardownPending) {
            // expected
        }
        assertEquals("refused at once, not after the deadline", 0L, currentTime - start)
        assertFalse("B" in env.dao.allRows())

        env.dao.failingClears.clear()
        assertTrue(env.lifecycle.runPendingTeardown())
        env.lifecycle.write(ctxB) { env.dao.saveDashboard(CachedDashboard(json = "B")) }
        assertEquals(listOf("B"), env.dao.allRows())
        env.scope.cancel()
    }

    @Test
    fun `a write queued behind an end is refused once the end has run`() = runTest {
        val env = Env(this)
        val a = env.installA()
        val ctxA = env.store.snapshot()!!
        val hold = CompletableDeferred<Unit>()
        env.scope.launch { env.lifecycle.write(ctxA) { hold.await() } } // holds the lock
        runCurrent()
        val end = env.scope.async { env.lifecycle.endIfCurrent(a, EndReason.UserSignedOut) }
        runCurrent() // the end is queued first
        val late = env.scope.async { runCatching { env.lifecycle.write(ctxA) { env.dao.saveDashboard(CachedDashboard(json = "A")) } } }
        runCurrent() // passed the check at entry (A was still current), queued behind the end

        hold.complete(Unit)
        runCurrent()

        assertNotNull(end.await())
        assertTrue(late.await().exceptionOrNull() is ApiError.SessionSuperseded)
        assertTrue(env.dao.allRows().isEmpty())
        env.scope.cancel()
    }

    // ── durability ──────────────────────────────────────

    @Test
    fun `after a process death the stored session and the cache agree`() = runTest {
        val env = Env(this)
        val a = env.installA()
        env.dao.fill("A")
        env.lifecycle.endIfCurrent(a, EndReason.UserSignedOut)
        val b = env.lifecycle.install("access-B", "refresh-B", "user-B")!!
        env.lifecycle.write(env.store.snapshot()!!) { env.dao.saveDashboard(CachedDashboard(json = "B")) }

        // The process dies now: only what reached disk survives, in both stores.
        val revived = TokenStore(env.prefs.restart())

        assertEquals("B's sign-in is on disk before B's rows are", b, revived.sessionId)
        assertEquals("refresh-B", revived.refreshToken)
        assertNull("A's teardown is recorded as done", revived.teardownPending)
        assertEquals(listOf("B"), env.dao.allRows())
        env.scope.cancel()
    }

    @Test
    fun `an end that did not reach disk deletes nothing and keeps writers out until it does`() = runTest {
        val env = Env(this)
        val a = env.installA()
        env.dao.fill("A")
        env.prefs.failCommits = true

        env.lifecycle.endIfCurrent(a, EndReason.UserSignedOut)

        assertEquals("no deletion before the end is durable", 6, FakeCacheDao.TABLES.sumOf { env.dao.rowCount(it) })
        env.store.installSession("access-B", "refresh-B", "user-B")
        val ctxB = env.store.snapshot()!!
        try {
            env.lifecycle.write(ctxB) { env.dao.saveDashboard(CachedDashboard(json = "B")) }
            fail("expected TeardownPending")
        } catch (e: ApiError.TeardownPending) {
            // expected
        }

        env.prefs.failCommits = false
        advanceTimeBy(env.lifecycle.retryMaxMillis + 1)
        runCurrent()
        assertTrue(env.store.isDurable)
        assertTrue(env.allTablesEmpty())
        assertNull(env.store.teardownPending)
        env.lifecycle.write(ctxB) { env.dao.saveDashboard(CachedDashboard(json = "B")) }
        assertEquals(listOf("B"), env.dao.allRows())
        env.scope.cancel()
    }

    // ── the repository's writes ─────────────────────────

    private class RepoWrite(
        val name: String,
        /** The CacheDao method this refresh writes with. */
        val daoCall: String,
        val stub: (SupabaseClient, CompletableDeferred<Unit>) -> Unit,
        val refresh: suspend (DashboardRepository) -> Unit,
        val flowEmpty: (DashboardRepository) -> Boolean,
    )

    private val repoWrites = listOf(
        RepoWrite(
            "dashboard", "saveDashboard",
            { s, gate -> coEvery { s.dashboard(any()) } coAnswers { gate.await(); DemoDataProvider.dashboard() } },
            { it.refreshDashboard() }, { it.dashboard.value == null },
        ),
        RepoWrite(
            "providers", "replaceProviders",
            { s, gate -> coEvery { s.providers(any()) } coAnswers { gate.await(); DemoDataProvider.providers() } },
            { it.refreshProviders() }, { it.providers.value.isEmpty() },
        ),
        RepoWrite(
            "sessions", "replaceSessions",
            { s, gate -> coEvery { s.sessions(any()) } coAnswers { gate.await(); DemoDataProvider.sessions() } },
            { it.refreshSessions() }, { it.sessions.value.isEmpty() },
        ),
        RepoWrite(
            "devices", "replaceDevices",
            { s, gate -> coEvery { s.devices(any()) } coAnswers { gate.await(); DemoDataProvider.devices() } },
            { it.refreshDevices() }, { it.devices.value.isEmpty() },
        ),
        RepoWrite(
            "alerts", "replaceAlerts",
            { s, gate -> coEvery { s.alerts(any()) } coAnswers { gate.await(); DemoDataProvider.alerts() } },
            { it.refreshAlerts() }, { it.alerts.value.isEmpty() },
        ),
        RepoWrite(
            "daily usage", "replaceDailyUsage",
            { s, gate -> coEvery { s.dailyUsage(any(), any()) } coAnswers { gate.await(); DemoDataProvider.dailyUsage(30) } },
            { it.refreshDailyUsage(30) }, { it.dailyUsage.value.isEmpty() },
        ),
    )

    @Test
    fun `a fetch that comes back after its session ended writes nothing, for each of the six writes`() = runTest {
        for (w in repoWrites) {
            // Positive control: the same write lands while its session is current.
            val live = Env(this)
            w.stub(live.supabase, CompletableDeferred(Unit))
            live.installA()
            w.refresh(live.repo)
            assertTrue("${w.name}: positive control", w.daoCall in live.dao.calls)
            assertFalse("${w.name}: positive control", w.flowEmpty(live.repo))
            live.scope.cancel()

            val env = Env(this)
            val gate = CompletableDeferred<Unit>()
            w.stub(env.supabase, gate)
            val a = env.installA()
            val refresh = env.scope.async { runCatching { w.refresh(env.repo) } }
            runCurrent() // the fetch is out, waiting at the gate

            env.lifecycle.endIfCurrent(a, EndReason.UserSignedOut)
            gate.complete(Unit)
            runCurrent()

            assertTrue("${w.name}: ${refresh.await().exceptionOrNull()}", refresh.await().exceptionOrNull() is ApiError.SessionSuperseded)
            assertFalse("${w.name}: written after the end", w.daoCall in env.dao.calls)
            assertTrue("${w.name}: shown after the end", w.flowEmpty(env.repo))
            assertTrue(env.dao.allRows().isEmpty())
            env.scope.cancel()
        }
    }

    @Test
    fun `a refusal in the background tears everything down with no screen open`() = runTest {
        val server = MockWebServer()
        server.start()
        try {
            val env = Env(this)
            val client = SupabaseClient(
                env.store,
                env.lifecycle,
                server.url("/").toString().trimEnd('/'),
                "anon-key-for-tests",
                OkHttpClient.Builder().retryOnConnectionFailure(false),
            )
            val repo = DashboardRepository(client, env.dao, env.store, env.lifecycle)
            env.store.installSession(TestJwt.expired(), "refresh-A", "user-A")
            env.dao.fill("A")
            server.enqueue(
                MockResponse().setResponseCode(400)
                    .setBody("""{"code":400,"error_code":"refresh_token_not_found","msg":"x"}"""),
            )

            val e = runCatching { repo.refreshDashboard() }.exceptionOrNull()

            assertTrue("got $e", e is ApiError.TokenExpired)
            assertNull(env.store.state.value.sessionId)
            assertEquals(EndReason.SessionRefused, env.store.state.value.endedReason)
            assertNull("the teardown ran inside the end", env.store.teardownPending)
            assertTrue(env.dao.allRows().isEmpty())
            assertNull(repo.dashboard.value)
            assertTrue(repo.dailyUsage.value.isEmpty())
            env.scope.cancel()
        } finally {
            server.shutdown()
        }
    }
}
