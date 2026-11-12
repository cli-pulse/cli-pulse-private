package com.clipulse.android.ui.settings

import com.clipulse.android.ui.common.UiError
import com.clipulse.android.MainDispatcherRule
import com.clipulse.android.data.local.CachedDashboard
import com.clipulse.android.data.local.FakeCacheDao
import com.clipulse.android.data.model.SettingsSnapshot
import com.clipulse.android.data.remote.ApiError
import com.clipulse.android.data.remote.EndReason
import com.clipulse.android.data.remote.SupabaseClient
import com.clipulse.android.data.remote.InMemorySharedPreferences
import com.clipulse.android.data.remote.TokenStore
import com.clipulse.android.data.remote.BlockedCommit
import com.clipulse.android.data.remote.BlockedCommit.Companion.returnsWithoutWaiting
import com.clipulse.android.data.session.SessionLifecycle
import com.clipulse.android.data.session.SessionScopedState
import io.mockk.coEvery
import io.mockk.coVerify
import io.mockk.mockk
import io.mockk.verify
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.awaitCancellation
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.cancel
import androidx.lifecycle.viewModelScope
import kotlinx.coroutines.test.runTest
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import java.io.IOException
import java.util.concurrent.atomic.AtomicInteger

/**
 * Real TokenStore and SessionLifecycle over an in-memory cache; the client is mocked. The
 * view model belongs to the session that was current when it was created, and every action,
 * sign-out and deletion included, runs for that session only.
 */
@OptIn(ExperimentalCoroutinesApi::class)
class SettingsViewModelTest {

    @get:Rule
    val mainDispatcherRule = MainDispatcherRule()

    private val supabase = mockk<SupabaseClient>(relaxed = true)
    // Its own scheduler, separate from the view model's: a test can cancel the view model's
    // scope first and show that sign-out's work still runs.
    private val appDispatcher = StandardTestDispatcher()
    private val appScope = CoroutineScope(SupervisorJob() + appDispatcher)

    private val prefs = InMemorySharedPreferences()
    private val store = TokenStore(prefs)
    private val dao = FakeCacheDao()
    private val lifecycle = SessionLifecycle(store, dao, appScope, Dispatchers.Unconfined)

    private val testSettings = SettingsSnapshot(
        notificationsEnabled = true,
        pushPolicy = "Critical Only",
        dataRetentionDays = 30,
        webhookEnabled = true,
        webhookUrl = "https://hooks.example.test/test",
    )

    private fun vm() = SettingsViewModel(supabase, store, lifecycle, appScope)

    private fun installA(): String =
        store.installSession("access-A", "refresh-A", "user-A", userName = "Name A", userEmail = "a@example.test")!!

    private fun assertCacheEmpty() {
        for (t in FakeCacheDao.TABLES) assertEquals("table $t", 0, dao.rowCount(t))
    }

    @Test
    fun `initial state has the owning session's user`() = runTest {
        installA()
        val vm = vm()

        assertEquals("Name A", vm.state.value.userName)
        assertEquals("a@example.test", vm.state.value.userEmail)
        vm.viewModelScope.cancel()
    }

    @Test
    fun `opening Settings does not wait for a commit in progress`() = runTest {
        val a = installA()
        BlockedCommit(prefs) { store.rotateIfCurrent(a, "access-A2", "refresh-A2") }.use {
            val vm = returnsWithoutWaiting("opening Settings") { vm() }
            assertEquals("Name A", vm.state.value.userName)
            vm.viewModelScope.cancel()
        }
    }

    @Test
    fun `loadSettings populates tier and settings`() = runTest {
        val a = installA()
        coEvery { supabase.serverTier(any()) } returns "pro"
        coEvery { supabase.settings(any()) } returns testSettings
        val vm = vm()

        val state = vm.state.value
        assertFalse(state.isLoading)
        assertEquals("pro", state.tier)
        assertTrue(state.webhookEnabled)
        assertEquals("https://hooks.example.test/test", state.webhookUrl)
        coVerify { supabase.settings(match { it?.sessionId == a }) }
        vm.viewModelScope.cancel()
    }

    @Test
    fun `loadSettings failure still clears loading`() = runTest {
        installA()
        coEvery { supabase.serverTier(any()) } throws RuntimeException("fail")
        val vm = vm()

        assertFalse(vm.state.value.isLoading)
        vm.viewModelScope.cancel()
    }

    @Test
    fun `updateSetting writes for the owning session and reloads`() = runTest {
        val a = installA()
        coEvery { supabase.settings(any()) } returns testSettings
        val vm = vm()

        vm.updateSetting("data_retention_days", 14)

        coVerify { supabase.updateSettings(any(), match { it?.sessionId == a }) }
        vm.viewModelScope.cancel()
    }

    @Test
    fun `demo mode shows demo user info and loads no account settings`() = runTest {
        store.enterDemoMode()
        val vm = vm()

        // The demo name is copy, so SettingsScreen renders it from R.string.settings_demo_user
        // in the app's language; the view model carries no English name.
        val state = vm.state.value
        assertNull(state.userName)
        assertEquals("demo@clipulse.app", state.userEmail)
        assertTrue(state.isDemoMode)
        assertFalse(state.isLoading)
        assertEquals("free", state.tier)
        assertNull(state.settings)
        coVerify(exactly = 0) { supabase.settings(any()) }
        coVerify(exactly = 0) { supabase.serverTier(any()) }
        coVerify(exactly = 0) { supabase.userIdentities(any()) }
        vm.viewModelScope.cancel()
    }

    @Test
    fun `sign-out ends the session, then revokes the token it captured`() = runTest {
        val a = installA()
        dao.fill("A")
        coEvery { supabase.revokeSession(any()) } answers {
            assertNull("the session is gone before the server is called", store.snapshot()?.accessToken)
        }
        val vm = vm()

        vm.signOut()
        appDispatcher.scheduler.advanceUntilIdle()

        assertNull(store.sessionId)
        assertEquals(EndReason.UserSignedOut, store.state.value.endedReason)
        coVerify(exactly = 1) { supabase.revokeSession("access-A") }
        assertCacheEmpty()
        assertNull(store.teardownPending)
        assertNull(store.endIfCurrent(a, EndReason.UserSignedOut))
        vm.viewModelScope.cancel()
    }

    @Test
    fun `sign-out deletes the cache even when the revocation fails`() = runTest {
        installA()
        dao.fill("A")
        coEvery { supabase.revokeSession(any()) } throws RuntimeException("network")
        val vm = vm()

        vm.signOut()
        appDispatcher.scheduler.advanceUntilIdle()

        assertCacheEmpty()
        vm.viewModelScope.cancel()
    }

    @Test
    fun `sign-out's work outlives the view model and does not wait on the network`() = runTest {
        installA()
        dao.fill("A")
        coEvery { supabase.revokeSession(any()) } coAnswers { awaitCancellation() }
        val vm = vm()

        vm.signOut()
        vm.viewModelScope.cancel() // the session's view models are cleared at once
        appDispatcher.scheduler.advanceUntilIdle()

        assertNull(store.sessionId)
        assertCacheEmpty()
        coVerify { supabase.revokeSession("access-A") }
    }

    @Test
    fun `a sign-out tapped on the previous account's screen leaves the next account alone`() = runTest {
        val a = installA()
        val vm = vm() // A's settings screen
        lifecycle.endIfCurrent(a, EndReason.SessionRefused)
        val b = lifecycle.install("access-B", "refresh-B", "user-B")!!
        lifecycle.write(store.snapshot()!!) { dao.saveDashboard(CachedDashboard(json = "B")) }

        vm.signOut() // a tap still queued on A's screen
        appDispatcher.scheduler.advanceUntilIdle()

        assertEquals(b, store.sessionId)
        assertEquals(listOf("B"), dao.allRows())
        coVerify(exactly = 0) { supabase.revokeSession(any()) }
        vm.viewModelScope.cancel()
    }

    @Test
    fun `a deletion tapped on the previous account's screen never targets the next account`() = runTest {
        val a = installA()
        val vm = vm()
        lifecycle.endIfCurrent(a, EndReason.SessionRefused)
        val b = lifecycle.install("access-B", "refresh-B", "user-B")!!
        lifecycle.write(store.snapshot()!!) { dao.saveDashboard(CachedDashboard(json = "B")) }

        vm.deleteAccount()
        appDispatcher.scheduler.advanceUntilIdle()

        coVerify(exactly = 0) { supabase.deleteAccount(match { it.sessionId == b }) }
        coVerify(exactly = 1) { supabase.deleteAccount(match { it.sessionId == a }) }
        assertEquals(b, store.sessionId)
        assertEquals(listOf("B"), dao.allRows())
        assertFalse(vm.state.value.deleteSuccess)
        vm.viewModelScope.cancel()
    }

    @Test
    fun `leaving demo mode ends the demo session and revokes nothing`() = runTest {
        val demo = store.enterDemoMode()
        val vm = vm()

        vm.exitDemoMode()
        appDispatcher.scheduler.advanceUntilIdle()

        assertNull(store.sessionId)
        assertFalse(store.isDemoMode)
        assertEquals(EndReason.DemoExit, store.state.value.endedReason)
        assertNull(store.endIfCurrent(demo, EndReason.DemoExit))
        verify { supabase.clearDemoState() }
        coVerify(exactly = 0) { supabase.revokeSession(any()) }
        vm.viewModelScope.cancel()
    }

    @Test
    fun `deleting the account removes every trace of it from the phone`() = runTest {
        val a = installA()
        store.setDeviceIdIfCurrent(a, "device-A")
        store.saveProviderKey("example", "provider-key-A")
        store.savePendingOAuthFlow(
            TokenStore.PendingOAuthFlow("link", "github", "verifier-A", "state-A", System.currentTimeMillis(), sessionId = a),
        )
        dao.fill("A")
        val memoryResets = AtomicInteger()
        lifecycle.register(object : SessionScopedState {
            override fun reset() {
                memoryResets.incrementAndGet()
            }
        })
        val vm = vm()

        vm.deleteAccount()
        appDispatcher.scheduler.advanceUntilIdle()

        assertTrue(vm.state.value.deleteSuccess)
        assertNull(vm.state.value.deleteError)
        coVerify(exactly = 1) { supabase.deleteAccount(match { it.sessionId == a }) }
        coVerify(exactly = 0) { supabase.revokeSession(any()) }
        assertNull(store.snapshot())
        assertEquals(EndReason.AccountDeleted, store.state.value.endedReason)
        assertNull(store.userName)
        assertNull(store.userEmail)
        assertNull(store.deviceIdFor(a))
        assertNull(store.loadPendingOAuthFlow())
        assertNull(store.loadProviderKey("example"))
        // An end keeps only the sign-in generation and the one-time cache check, neither of
        // them about any account; the same on disk.
        val kept = setOf("auth_generation", "legacy_cache_checked")
        assertEquals(kept, prefs.all.keys)
        assertEquals(kept, prefs.durableSnapshot().keys)
        assertCacheEmpty()
        assertEquals("the repository's in-memory rows were emptied", 1, memoryResets.get())
        assertNull(store.teardownPending)
        vm.viewModelScope.cancel()
    }

    @Test
    fun `a deletion that succeeds after the next account signed in leaves it alone and shows nothing`() = runTest {
        installA()
        dao.fill("A")
        val answer = CompletableDeferred<Unit>()
        coEvery { supabase.deleteAccount(any()) } coAnswers { answer.await() }
        val vm = vm()

        vm.deleteAccount() // A's request is out
        val b = lifecycle.install("access-B", "refresh-B", "user-B")!! // B signs in meanwhile
        lifecycle.write(store.snapshot()!!) { dao.saveDashboard(CachedDashboard(json = "B")) }
        answer.complete(Unit) // and A's deletion answers with success now
        appDispatcher.scheduler.advanceUntilIdle()

        assertEquals(b, store.sessionId)
        assertEquals("access-B", store.snapshot()?.accessToken)
        assertEquals("refresh-B", store.snapshot()?.refreshToken)
        assertEquals(listOf("B"), dao.allRows())
        assertNull(store.teardownPending)
        assertNull(store.state.value.endedReason)
        assertFalse(vm.state.value.deleteSuccess)
        assertNull(vm.state.value.deleteError)
        assertFalse(vm.state.value.isLoading)
        vm.viewModelScope.cancel()
    }

    @Test
    fun `a deletion that fails on the way deletes nothing and reports the failure`() = runTest {
        val a = installA()
        dao.fill("A")
        for (failure in listOf(IOException("offline"), ApiError.Http(503, "unavailable"))) {
            coEvery { supabase.deleteAccount(any()) } throws failure
            val vm = vm()

            vm.deleteAccount()
            appDispatcher.scheduler.advanceUntilIdle()

            val error = vm.state.value.deleteError
            assertTrue("$failure: $error", error is UiError.ActionFailed && error.action == UiError.Action.DeleteAccount)
            assertFalse(vm.state.value.deleteSuccess)
            assertFalse(vm.state.value.isLoading)
            assertEquals(a, store.sessionId)
            assertEquals("access-A", store.snapshot()?.accessToken)
            assertEquals("refresh-A", store.snapshot()?.refreshToken)
            assertEquals(6, FakeCacheDao.TABLES.sumOf { dao.rowCount(it) })
            assertNull(store.teardownPending)
            vm.viewModelScope.cancel()
        }
    }

    @Test
    fun `a refusal while the deletion was out ends the session and says so, not that the deletion failed`() = runTest {
        val a = installA()
        dao.fill("A")
        coEvery { supabase.deleteAccount(any()) } coAnswers {
            // What the client does when the server says the session is gone (D1's allowlist).
            lifecycle.endIfCurrent(a, EndReason.SessionGone)
            throw ApiError.TokenExpired
        }
        val vm = vm()

        vm.deleteAccount()
        appDispatcher.scheduler.advanceUntilIdle()

        assertNull(store.sessionId)
        assertEquals(EndReason.SessionGone, store.state.value.endedReason)
        assertCacheEmpty()
        assertFalse(vm.state.value.deleteSuccess)
        assertEquals(UiError.SessionExpired, vm.state.value.deleteError)
        vm.viewModelScope.cancel()
    }

    @Test
    fun `a deletion overtaken by a session change shows nothing`() = runTest {
        installA()
        coEvery { supabase.deleteAccount(any()) } throws ApiError.SessionSuperseded
        val vm = vm()

        vm.deleteAccount()
        appDispatcher.scheduler.advanceUntilIdle()

        assertNull(vm.state.value.deleteError)
        assertFalse(vm.state.value.deleteSuccess)
        assertFalse(vm.state.value.isLoading)
        vm.viewModelScope.cancel()
    }

    @Test
    fun `a failed deletion keeps the session and reports the error`() = runTest {
        val id = installA()
        dao.fill("A")
        coEvery { supabase.deleteAccount(any()) } throws RuntimeException("server error")
        val vm = vm()

        vm.deleteAccount()
        appDispatcher.scheduler.advanceUntilIdle()

        assertFalse(vm.state.value.deleteSuccess)
        assertEquals(
            UiError.ActionFailed(UiError.Action.DeleteAccount, UiError.Unknown("server error")),
            vm.state.value.deleteError,
        )
        assertEquals(id, store.sessionId)
        assertEquals(6, FakeCacheDao.TABLES.sumOf { dao.rowCount(it) })
        vm.viewModelScope.cancel()
    }
}
