package com.clipulse.android.ui.settings

import com.clipulse.android.ui.common.UiError
import com.clipulse.android.MainDispatcherRule
import com.clipulse.android.data.local.FakeCacheDao
import com.clipulse.android.data.model.SettingsSnapshot
import com.clipulse.android.data.remote.EndReason
import com.clipulse.android.data.remote.SupabaseClient
import com.clipulse.android.data.remote.InMemorySharedPreferences
import com.clipulse.android.data.remote.TokenStore
import com.clipulse.android.data.session.SessionLifecycle
import io.mockk.coEvery
import io.mockk.coVerify
import io.mockk.every
import io.mockk.mockk
import io.mockk.verify
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.awaitCancellation
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.cancel
import androidx.lifecycle.viewModelScope
import kotlinx.coroutines.test.runTest
import org.junit.Assert.*
import org.junit.Before
import org.junit.Rule
import org.junit.Test

@OptIn(ExperimentalCoroutinesApi::class)
class SettingsViewModelTest {

    @get:Rule
    val mainDispatcherRule = MainDispatcherRule()

    private val supabase = mockk<SupabaseClient>(relaxed = true)
    private val tokenStore = mockk<TokenStore>(relaxed = true)
    private val lifecycle = mockk<SessionLifecycle>(relaxed = true)
    // Its own scheduler, separate from the view model's: a test can cancel the view model's
    // scope first and show that sign-out's work still runs.
    private val appDispatcher = StandardTestDispatcher()
    private val appScope = CoroutineScope(SupervisorJob() + appDispatcher)

    // A real session for the sign-out, demo and delete tests: a real store, a real lifecycle
    // and an in-memory cache, so the assertions are about what is actually left behind.
    private val realStore = TokenStore(InMemorySharedPreferences())
    private val dao = FakeCacheDao()
    private val realLifecycle = SessionLifecycle(realStore, dao, appScope)

    private val testSettings = SettingsSnapshot(
        notificationsEnabled = true,
        pushPolicy = "Critical Only",
        dataRetentionDays = 30,
        webhookEnabled = true,
        webhookUrl = "https://hooks.slack.com/test",
    )

    @Before
    fun setUp() {
        every { tokenStore.isDemoMode } returns false
        every { tokenStore.userName } returns "Jason"
        every { tokenStore.userEmail } returns "jason@test.com"
    }

    private fun realVm() = SettingsViewModel(supabase, realStore, realLifecycle, appScope)

    private fun assertCacheEmpty() {
        for (t in FakeCacheDao.TABLES) assertEquals("table $t", 0, dao.rowCount(t))
    }

    @Test
    fun `initial state has user info from token store`() = runTest {
        coEvery { supabase.serverTier() } returns "pro"
        coEvery { supabase.settings() } returns testSettings
        val vm = SettingsViewModel(supabase, tokenStore, lifecycle, appScope)

        assertEquals("Jason", vm.state.value.userName)
        assertEquals("jason@test.com", vm.state.value.userEmail)
        vm.viewModelScope.cancel()
    }

    @Test
    fun `loadSettings populates tier and settings`() = runTest {
        coEvery { supabase.serverTier() } returns "pro"
        coEvery { supabase.settings() } returns testSettings
        val vm = SettingsViewModel(supabase, tokenStore, lifecycle, appScope)

        val state = vm.state.value
        assertFalse(state.isLoading)
        assertEquals("pro", state.tier)
        assertTrue(state.webhookEnabled)
        assertEquals("https://hooks.slack.com/test", state.webhookUrl)
        vm.viewModelScope.cancel()
    }

    @Test
    fun `loadSettings failure still clears loading`() = runTest {
        coEvery { supabase.serverTier() } throws RuntimeException("fail")
        val vm = SettingsViewModel(supabase, tokenStore, lifecycle, appScope)

        assertFalse(vm.state.value.isLoading)
        vm.viewModelScope.cancel()
    }

    @Test
    fun `updateSetting calls supabase and reloads`() = runTest {
        coEvery { supabase.serverTier() } returns "pro"
        coEvery { supabase.settings() } returns testSettings
        val vm = SettingsViewModel(supabase, tokenStore, lifecycle, appScope)

        vm.updateSetting("data_retention_days", 14)

        coVerify { supabase.updateSettings(any()) }
        vm.viewModelScope.cancel()
    }

    @Test
    fun `demo mode shows demo user info`() = runTest {
        every { tokenStore.isDemoMode } returns true
        coEvery { supabase.serverTier() } returns "free"
        coEvery { supabase.settings() } returns testSettings
        val vm = SettingsViewModel(supabase, tokenStore, lifecycle, appScope)

        // The demo name is copy, so SettingsScreen renders it from R.string.settings_demo_user
        // in the app's language; the view model carries no English name.
        assertNull(vm.state.value.userName)
        assertEquals("demo@clipulse.app", vm.state.value.userEmail)
        assertTrue(vm.state.value.isDemoMode)
        vm.viewModelScope.cancel()
    }

    @Test
    fun `demo mode loads no account settings`() = runTest {
        every { tokenStore.isDemoMode } returns true
        val vm = SettingsViewModel(supabase, tokenStore, lifecycle, appScope)

        val state = vm.state.value
        assertFalse(state.isLoading)
        assertEquals("free", state.tier)
        assertNull(state.settings)
        coVerify(exactly = 0) { supabase.settings() }
        coVerify(exactly = 0) { supabase.serverTier() }
        coVerify(exactly = 0) { supabase.userIdentities() }
        vm.viewModelScope.cancel()
    }

    @Test
    fun `sign-out ends the session in one step, then revokes the token it captured`() = runTest {
        val id = realStore.installSession("access-1", "refresh-1", "user-1")!!
        dao.fill("A")
        coEvery { supabase.revokeSession(any()) } answers {
            assertNull("the session is gone before the server is called", realStore.accessToken)
        }
        val vm = realVm()

        vm.signOut()
        assertNull("ended before the screen changes", realStore.sessionId)
        assertEquals(EndReason.UserSignedOut, realStore.state.value.endedReason)
        appDispatcher.scheduler.advanceUntilIdle()

        coVerify(exactly = 1) { supabase.revokeSession("access-1") }
        assertCacheEmpty()
        assertNull(realStore.teardownPending)
        assertNull(realStore.endIfCurrent(id, EndReason.UserSignedOut))
        vm.viewModelScope.cancel()
    }

    @Test
    fun `sign-out deletes the cache even when the revocation fails`() = runTest {
        realStore.installSession("access-1", "refresh-1", "user-1")
        dao.fill("A")
        coEvery { supabase.revokeSession(any()) } throws RuntimeException("network")
        val vm = realVm()

        vm.signOut()
        appDispatcher.scheduler.advanceUntilIdle()

        assertCacheEmpty()
        vm.viewModelScope.cancel()
    }

    @Test
    fun `sign-out's work outlives the view model and does not wait on the network`() = runTest {
        realStore.installSession("access-1", "refresh-1", "user-1")
        dao.fill("A")
        coEvery { supabase.revokeSession(any()) } coAnswers { awaitCancellation() }
        val vm = realVm()

        vm.signOut()
        vm.viewModelScope.cancel() // the session's view models are cleared at once
        appDispatcher.scheduler.advanceUntilIdle()

        assertNull(realStore.sessionId)
        assertCacheEmpty()
        coVerify { supabase.revokeSession("access-1") }
    }

    @Test
    fun `leaving demo mode ends the demo session and revokes nothing`() = runTest {
        val demo = realStore.enterDemoMode()
        val vm = realVm()

        vm.exitDemoMode()
        appDispatcher.scheduler.advanceUntilIdle()

        assertNull(realStore.sessionId)
        assertFalse(realStore.isDemoMode)
        assertEquals(EndReason.DemoExit, realStore.state.value.endedReason)
        assertNull(realStore.endIfCurrent(demo, EndReason.DemoExit))
        verify { supabase.clearDemoState() }
        coVerify(exactly = 0) { supabase.revokeSession(any()) }
        vm.viewModelScope.cancel()
    }

    @Test
    fun `deleting the account removes it from the device too`() = runTest {
        realStore.installSession("access-1", "refresh-1", "user-1")
        dao.fill("A")
        val vm = realVm()

        vm.deleteAccount()
        appDispatcher.scheduler.advanceUntilIdle()

        assertTrue(vm.state.value.deleteSuccess)
        coVerify(exactly = 1) { supabase.deleteAccount(any()) }
        assertNull(realStore.sessionId)
        assertEquals(EndReason.AccountDeleted, realStore.state.value.endedReason)
        assertCacheEmpty()
        vm.viewModelScope.cancel()
    }

    @Test
    fun `a failed deletion keeps the session and reports the error`() = runTest {
        val id = realStore.installSession("access-1", "refresh-1", "user-1")!!
        dao.fill("A")
        coEvery { supabase.deleteAccount(any()) } throws RuntimeException("server error")
        val vm = realVm()

        vm.deleteAccount()
        appDispatcher.scheduler.advanceUntilIdle()

        assertFalse(vm.state.value.deleteSuccess)
        assertEquals(
            UiError.ActionFailed(UiError.Action.DeleteAccount, UiError.Unknown("server error")),
            vm.state.value.deleteError,
        )
        assertEquals(id, realStore.sessionId)
        assertEquals(6, FakeCacheDao.TABLES.sumOf { dao.rowCount(it) })
        vm.viewModelScope.cancel()
    }
}
