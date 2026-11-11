package com.clipulse.android.ui.navigation

import androidx.lifecycle.SavedStateHandle
import androidx.lifecycle.viewModelScope
import com.clipulse.android.MainDispatcherRule
import com.clipulse.android.data.local.FakeCacheDao
import com.clipulse.android.data.model.AuthResponse
import com.clipulse.android.data.model.UserDTO
import com.clipulse.android.data.remote.ApiError
import com.clipulse.android.data.remote.EndReason
import com.clipulse.android.data.remote.InMemorySharedPreferences
import com.clipulse.android.data.remote.SessionContext
import com.clipulse.android.data.remote.SupabaseClient
import com.clipulse.android.data.remote.TokenStore
import com.clipulse.android.data.remote.BlockedCommit
import com.clipulse.android.data.remote.BlockedCommit.Companion.returnsWithoutWaiting
import com.clipulse.android.data.session.SessionLifecycle
import com.clipulse.android.ui.common.UiError
import io.mockk.coEvery
import io.mockk.coVerify
import io.mockk.mockk
import okhttp3.OkHttpClient
import okhttp3.mockwebserver.Dispatcher
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import okhttp3.mockwebserver.RecordedRequest
import com.clipulse.android.data.remote.TestJwt
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.test.UnconfinedTestDispatcher
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Rule
import org.junit.Test
import java.io.IOException

/**
 * The real gate state machine over a real TokenStore and SessionLifecycle; only the client is
 * mocked. "Rotation" is the same view model instance; "process death" is a new one built from
 * the SavedStateHandle the old one wrote.
 */
@OptIn(ExperimentalCoroutinesApi::class)
class SessionGateViewModelTest {

    @get:Rule
    val mainDispatcherRule = MainDispatcherRule()

    private val prefs = InMemorySharedPreferences()
    private val store = TokenStore(prefs)
    private val dao = FakeCacheDao()
    private val appScope = CoroutineScope(SupervisorJob() + UnconfinedTestDispatcher())
    private val lifecycle = SessionLifecycle(store, dao, appScope, Dispatchers.Unconfined)
    private val supabase = mockk<SupabaseClient>(relaxed = true)

    private fun gate(handle: SavedStateHandle = SavedStateHandle(), lc: SessionLifecycle = lifecycle) =
        SessionGateViewModel(handle, store, supabase, lc)

    private fun auth(sessionId: String) = AuthResponse(
        access_token = "access",
        refresh_token = "refresh",
        user = UserDTO(id = "u", name = "n", email = "e@example.test"),
        paired = false,
        sessionId = sessionId,
    )

    private fun meAnswers() {
        coEvery { supabase.me(any()) } coAnswers { auth(firstArg<SessionContext?>()!!.sessionId) }
    }

    private fun installA(): String = store.installSession("access-A", "refresh-A", "user-A")!!

    private fun saved(screen: GateScreen, session: String?, epoch: Int) = SavedStateHandle(
        mapOf(
            SessionGateViewModel.KEY_SCREEN to screen.name,
            SessionGateViewModel.KEY_SESSION to session,
            SessionGateViewModel.KEY_EPOCH to epoch,
        ),
    )

    /** A gate already on the tabs for a fresh session A. */
    private fun onTabsWithA(): Pair<SessionGateViewModel, String> {
        meAnswers()
        val a = installA()
        val g = gate()
        assertEquals(GateScreen.Tabs, g.state.value.screen)
        return g to a
    }

    @Test
    fun `signed out at start shows the sign-in screen and checks nothing`() = runTest {
        val g = gate()
        assertEquals(GateScreen.Login, g.state.value.screen)
        coVerify(exactly = 0) { supabase.me(any()) }
        g.viewModelScope.cancel()
    }

    @Test
    fun `restoring a session does not wait for a commit in progress`() = runTest {
        meAnswers()
        val a = installA()
        BlockedCommit(prefs) { store.rotateIfCurrent(a, "access-A2", "refresh-A2") }.use {
            val g = returnsWithoutWaiting("the gate's restore") { gate() }
            assertEquals(GateState(GateScreen.Tabs, a, 0), g.state.value)
            g.viewModelScope.cancel()
        }
    }

    @Test
    fun `a saved session is checked once, then the tabs show`() = runTest {
        meAnswers()
        val a = installA()

        val g = gate()

        assertEquals(GateState(GateScreen.Tabs, a, 0), g.state.value)
        coVerify(exactly = 1) { supabase.me(match { it.sessionId == a }) }
        g.viewModelScope.cancel()
    }

    @Test
    fun `a rotation on the tabs keeps them and checks nothing again`() = runTest {
        val (g, a) = onTabsWithA()
        // Same view model instance across the rotation; a renewal in the meantime changes nothing.
        store.rotateIfCurrent(a, "access-A2", "refresh-A2")

        assertEquals(GateState(GateScreen.Tabs, a, 0), g.state.value)
        coVerify(exactly = 1) { supabase.me(any()) }
        g.viewModelScope.cancel()
    }

    @Test
    fun `a rotation while restoring does not start a second check`() = runTest {
        val answer = CompletableDeferred<AuthResponse>()
        coEvery { supabase.me(any()) } coAnswers { answer.await() }
        val a = installA()
        val g = gate()
        assertEquals(GateScreen.Restoring, g.state.value.screen)

        store.rotateIfCurrent(a, "access-A2", "refresh-A2")
        answer.complete(auth(a))

        assertEquals(GateState(GateScreen.Tabs, a, 0), g.state.value)
        coVerify(exactly = 1) { supabase.me(any()) }
        g.viewModelScope.cancel()
    }

    @Test
    fun `after a process death a saved restore runs again exactly once`() = runTest {
        meAnswers()
        val a = installA()

        val g = gate(saved(GateScreen.Restoring, a, 3))

        assertEquals(GateState(GateScreen.Tabs, a, 3), g.state.value)
        coVerify(exactly = 1) { supabase.me(any()) }
        g.viewModelScope.cancel()
    }

    @Test
    fun `after a process death a saved restore of a session that is gone shows the sign-in screen`() = runTest {
        meAnswers()

        val g = gate(saved(GateScreen.Restoring, "session-gone", 3))

        assertEquals(GateScreen.Login, g.state.value.screen)
        assertNull(g.state.value.activeSessionId)
        coVerify(exactly = 0) { supabase.me(any()) }
        g.viewModelScope.cancel()
    }

    @Test
    fun `after a process death saved tabs stay without a check`() = runTest {
        meAnswers()
        val a = installA()

        val g = gate(saved(GateScreen.Tabs, a, 2))

        assertEquals(GateState(GateScreen.Tabs, a, 2), g.state.value)
        coVerify(exactly = 0) { supabase.me(any()) }
        g.viewModelScope.cancel()
    }

    @Test
    fun `the saved state round-trips through a process death`() = runTest {
        val (g, a) = onTabsWithA()
        val handle = SavedStateHandle()
        val first = gate(handle)
        first.viewModelScope.cancel()

        val second = gate(handle)

        assertEquals(GateState(GateScreen.Tabs, a, 0), second.state.value)
        g.viewModelScope.cancel()
        second.viewModelScope.cancel()
    }

    @Test
    fun `sign-out moves the epoch exactly once`() = runTest {
        val (g, _) = onTabsWithA()

        lifecycle.endCurrent(EndReason.UserSignedOut) // what Settings' sign-out does

        assertEquals(GateState(GateScreen.Login, null, 1), g.state.value)
        assertNull("the teardown's own state change does not count again", store.teardownPending)
        g.viewModelScope.cancel()
    }

    @Test
    fun `account deletion moves the epoch exactly once`() = runTest {
        val (g, a) = onTabsWithA()

        lifecycle.endIfCurrent(a, EndReason.AccountDeleted)

        assertEquals(GateState(GateScreen.Login, null, 1), g.state.value)
        g.viewModelScope.cancel()
    }

    @Test
    fun `leaving demo mode moves the epoch exactly once`() = runTest {
        val demo = store.enterDemoMode()
        val g = gate()
        assertEquals(GateState(GateScreen.Tabs, demo, 0), g.state.value)

        lifecycle.endIfCurrent(demo, EndReason.DemoExit)

        assertEquals(GateState(GateScreen.Login, null, 1), g.state.value)
        coVerify(exactly = 0) { supabase.me(any()) }
        g.viewModelScope.cancel()
    }

    @Test
    fun `a refusal on the tabs moves the epoch once and says the session expired`() = runTest {
        val (g, a) = onTabsWithA()

        store.endIfCurrent(a, EndReason.SessionRefused) // what the client does on a refusal

        assertEquals(GateState(GateScreen.Login, null, 1, notice = UiError.SessionExpired), g.state.value)
        g.viewModelScope.cancel()
    }

    @Test
    fun `A replaced by B with no signed-out state in between moves the epoch and checks B`() = runTest {
        val (g, a) = onTabsWithA()

        val b = store.installSession("access-B", "refresh-B", "user-B")!! // straight over A

        assertEquals(GateState(GateScreen.Tabs, b, 1), g.state.value)
        coVerify(exactly = 1) { supabase.me(match { it.sessionId == a }) }
        coVerify(exactly = 1) { supabase.me(match { it.sessionId == b }) }
        g.viewModelScope.cancel()
    }

    @Test
    fun `a sign-in on the sign-in screen shows the tabs for its session, unchecked`() = runTest {
        meAnswers()
        val g = gate()

        val b = installA()
        assertEquals("waits for the sign-in to complete", GateScreen.Login, g.state.value.screen)
        g.onLoggedIn(b)

        assertEquals(GateState(GateScreen.Tabs, b, 0), g.state.value)
        coVerify(exactly = 0) { supabase.me(any()) }
        g.viewModelScope.cancel()
    }

    @Test
    fun `a stale sign-in completion is ignored`() = runTest {
        val g = gate()
        val a = installA()
        store.endIfCurrent(a, EndReason.UserSignedOut)
        val b = store.installSession("access-B", "refresh-B", "user-B")!!

        g.onLoggedIn(a)
        assertEquals(GateScreen.Login, g.state.value.screen)

        g.onLoggedIn(b)
        assertEquals(GateState(GateScreen.Tabs, b, 0), g.state.value)
        g.viewModelScope.cancel()
    }

    @Test
    fun `entering demo mode from the sign-in screen shows the tabs without a check`() = runTest {
        val g = gate()

        val demo = store.enterDemoMode()
        g.onLoggedIn(demo)

        assertEquals(GateState(GateScreen.Tabs, demo, 0), g.state.value)
        coVerify(exactly = 0) { supabase.me(any()) }
        g.viewModelScope.cancel()
    }

    // ── what the check runs into ────────────────────────

    @Test
    fun `a refused check ends the session through the lifecycle, never by itself`() = runTest {
        val a = installA()
        coEvery { supabase.me(any()) } throws ApiError.TokenExpired
        val mockLifecycle = mockk<SessionLifecycle>(relaxed = true)

        val g = gate(lc = mockLifecycle)

        coVerify(exactly = 1) { mockLifecycle.endIfCurrent(a, EndReason.SessionRefused) }
        // The gate itself wiped nothing: with the lifecycle mocked, the session is still there.
        assertEquals(a, store.sessionId)
        g.viewModelScope.cancel()
    }

    @Test
    fun `a refused check ends the session and shows the sign-in screen`() = runTest {
        val a = installA()
        coEvery { supabase.me(any()) } throws ApiError.TokenExpired

        val g = gate()

        assertEquals(GateState(GateScreen.Login, null, 0, notice = UiError.SessionExpired), g.state.value)
        assertNull(store.sessionId)
        assertEquals(EndReason.SessionRefused, store.state.value.endedReason)
        assertNull(store.endIfCurrent(a, EndReason.SessionRefused))
        g.viewModelScope.cancel()
    }

    @Test
    fun `a check overtaken by the next account moves on to that account`() = runTest {
        val a = installA()
        var b: String? = null
        coEvery { supabase.me(any()) } coAnswers {
            val ctx = firstArg<SessionContext?>()!!
            if (ctx.sessionId == a) {
                b = store.installSession("access-B", "refresh-B", "user-B")
                throw ApiError.SessionSuperseded
            }
            auth(ctx.sessionId)
        }

        val g = gate()

        assertEquals(GateState(GateScreen.Tabs, b, 0), g.state.value)
        g.viewModelScope.cancel()
    }

    @Test
    fun `a network or server error keeps the session and shows the tabs`() = runTest {
        val cases = listOf(
            IOException("offline") to UiError.OfflineUsingCachedSession,
            ApiError.Http(503, "") to UiError.OfflineUsingCachedSession,
            ApiError.Http(429, "") to UiError.OfflineUsingCachedSession,
            ApiError.Http(403, """{"error_code":"not_admin"}""") to UiError.Server(403),
            ApiError.Http(401, "<html>proxy</html>") to UiError.Server(401),
        )
        for ((error, shown) in cases) {
            val a = store.installSession("access-A", "refresh-A", "user-A")!!
            coEvery { supabase.me(any()) } throws error

            val g = gate()

            assertEquals("$error", GateState(GateScreen.Tabs, a, 0, restoreError = shown), g.state.value)
            assertEquals(a, store.sessionId)
            g.viewModelScope.cancel()
        }
    }

    @Test
    fun `the session expired notice survives a process death with the sign-in screen`() = runTest {
        val (g, a) = onTabsWithA()
        val handle = SavedStateHandle()
        val live = gate(handle)
        store.endIfCurrent(a, EndReason.SessionRefused)
        assertEquals(UiError.SessionExpired, live.state.value.notice)

        val revived = gate(handle)

        assertEquals(GateScreen.Login, revived.state.value.screen)
        assertEquals(UiError.SessionExpired, revived.state.value.notice)
        g.viewModelScope.cancel()
        live.viewModelScope.cancel()
        revived.viewModelScope.cancel()
    }

    @Test
    fun `a 1_62 session with an expired token renews once and lands on the tabs`() = runTest {
        val server = MockWebServer()
        server.start()
        try {
            // What 1.62 left in the encrypted preferences: tokens and a user id, no session id.
            val legacy = InMemorySharedPreferences()
            legacy.edit()
                .putString("access_token", TestJwt.expired())
                .putString("refresh_token", "refresh-old")
                .putString("user_id", "user-a")
                .apply()
            val legacyStore = TokenStore(legacy)
            val legacyLifecycle = SessionLifecycle(legacyStore, FakeCacheDao(), appScope, Dispatchers.Unconfined)
            val client = SupabaseClient(
                legacyStore,
                legacyLifecycle,
                server.url("/").toString().trimEnd('/'),
                "anon-key-for-tests",
                OkHttpClient.Builder().retryOnConnectionFailure(false),
            )
            val refreshes = java.util.concurrent.atomic.AtomicInteger(0)
            server.dispatcher = object : Dispatcher() {
                override fun dispatch(request: RecordedRequest): MockResponse = when {
                    request.path!!.startsWith("/auth/v1/token?grant_type=refresh_token") -> {
                        refreshes.incrementAndGet()
                        MockResponse().setResponseCode(200)
                            .setBody("""{"access_token":"${TestJwt.fresh()}","refresh_token":"refresh-new"}""")
                    }
                    request.path == "/auth/v1/user" -> MockResponse().setResponseCode(200).setBody("""{"id":"user-a"}""")
                    else -> MockResponse().setResponseCode(200).setBody("[]")
                }
            }
            val id = legacyStore.sessionId!!

            val g = SessionGateViewModel(SavedStateHandle(), legacyStore, client, legacyLifecycle)
            val landed = g.state.first { it.screen != GateScreen.Restoring }

            assertEquals(GateState(GateScreen.Tabs, id, 0), landed)
            assertEquals("exactly one renewal", 1, refreshes.get())
            assertEquals("refresh-new", legacyStore.refreshToken)
            g.viewModelScope.cancel()
        } finally {
            server.shutdown()
        }
    }
}
