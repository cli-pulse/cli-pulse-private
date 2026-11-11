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
import kotlinx.coroutines.async
import okhttp3.OkHttpClient
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
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

    // ── the repository's writes ─────────────────────────

    /** A store, an in-memory cache, a lifecycle on the test scheduler and a repository over a mocked client. */
    private class Env(testScope: TestScope) {
        val store = TokenStore(InMemorySharedPreferences())
        val dao = FakeCacheDao()
        val scope = CoroutineScope(SupervisorJob() + StandardTestDispatcher(testScope.testScheduler))
        val lifecycle = SessionLifecycle(store, dao, scope)
        val supabase = mockk<SupabaseClient>(relaxed = true)
        val repo = DashboardRepository(supabase, dao, store, lifecycle)
    }

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
            live.store.installSession("access-A", "refresh-A", "user-A")
            w.refresh(live.repo)
            assertTrue("${w.name}: positive control", w.daoCall in live.dao.calls)
            assertFalse("${w.name}: positive control", w.flowEmpty(live.repo))
            live.scope.cancel()

            val env = Env(this)
            val gate = CompletableDeferred<Unit>()
            w.stub(env.supabase, gate)
            val a = env.store.installSession("access-A", "refresh-A", "user-A")!!
            val refresh = env.scope.async { runCatching { w.refresh(env.repo) } }
            runCurrent() // the fetch is out, waiting at the gate

            env.lifecycle.endIfCurrent(a, EndReason.UserSignedOut)
            runCurrent() // the teardown has run
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
    fun `hydration from the cache never shows an ended session's rows`() = runTest {
        val env = Env(this)
        coEvery { env.supabase.dashboard(any()) } returns DemoDataProvider.dashboard()
        val a = env.store.installSession("access-A", "refresh-A", "user-A")!!
        env.repo.refreshDashboard()
        assertTrue("A's row is cached", "saveDashboard" in env.dao.calls)

        env.lifecycle.endIfCurrent(a, EndReason.UserSignedOut)
        env.repo.loadFromCache()
        assertNull("nothing to hydrate for no session", env.repo.dashboard.value)

        // B signs in before A's teardown ran: B's hydration waits for it, then finds nothing of A's.
        env.store.installSession("access-B", "refresh-B", "user-B")
        val hydration = env.scope.async { env.repo.loadFromCache() }
        runCurrent()
        hydration.await()
        assertNull(env.repo.dashboard.value)
        assertTrue(env.dao.allRows().isEmpty())
        env.scope.cancel()
    }

    @Test
    fun `a refusal in the background tears everything down with no screen open`() = runTest {
        val server = MockWebServer()
        server.start()
        try {
            val env = Env(this)
            val client = SupabaseClient(
                env.store,
                server.url("/").toString().trimEnd('/'),
                "anon-key-for-tests",
                OkHttpClient.Builder().retryOnConnectionFailure(false),
            )
            val repo = DashboardRepository(client, env.dao, env.store, env.lifecycle)
            env.lifecycle.start()
            runCurrent()
            env.store.installSession(TestJwt.expired(), "refresh-A", "user-A")
            env.dao.fill("A")
            server.enqueue(
                MockResponse().setResponseCode(400)
                    .setBody("""{"code":400,"error_code":"refresh_token_not_found","msg":"x"}"""),
            )

            val e = runCatching { repo.refreshDashboard() }.exceptionOrNull()
            runCurrent()

            assertTrue("got $e", e is ApiError.TokenExpired)
            assertNull(env.store.state.value.sessionId)
            assertEquals(EndReason.SessionRefused, env.store.state.value.endedReason)
            assertNull("the teardown ran", env.store.teardownPending)
            assertTrue(env.dao.allRows().isEmpty())
            assertNull(repo.dashboard.value)
            assertTrue(repo.dailyUsage.value.isEmpty())
            env.scope.cancel()
        } finally {
            server.shutdown()
        }
    }
}
