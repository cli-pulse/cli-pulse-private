package com.clipulse.android.ui.settings

import com.clipulse.android.ui.common.UiError
import com.clipulse.android.MainDispatcherRule
import com.clipulse.android.data.local.CacheDao
import com.clipulse.android.data.model.SettingsSnapshot
import com.clipulse.android.data.remote.SupabaseClient
import com.clipulse.android.data.remote.InMemorySharedPreferences
import com.clipulse.android.data.remote.TokenStore
import com.clipulse.android.data.repository.DashboardRepository
import io.mockk.coEvery
import io.mockk.coVerify
import io.mockk.every
import io.mockk.mockk
import io.mockk.verify
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.awaitCancellation
import kotlinx.coroutines.delay
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
    private val cache = mockk<CacheDao>(relaxed = true)
    private val repository = mockk<DashboardRepository>(relaxed = true)
    // Its own scheduler, separate from the view model's: a test can cancel the view model's
    // scope first and show that sign-out's work still runs.
    private val appDispatcher = StandardTestDispatcher()
    private val appScope = CoroutineScope(SupervisorJob() + appDispatcher)

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

    @Test
    fun `initial state has user info from token store`() = runTest {
        coEvery { supabase.serverTier() } returns "pro"
        coEvery { supabase.settings() } returns testSettings
        val vm = SettingsViewModel(supabase, tokenStore, cache, repository, appScope)

        assertEquals("Jason", vm.state.value.userName)
        assertEquals("jason@test.com", vm.state.value.userEmail)
        vm.viewModelScope.cancel()
    }

    @Test
    fun `loadSettings populates tier and settings`() = runTest {
        coEvery { supabase.serverTier() } returns "pro"
        coEvery { supabase.settings() } returns testSettings
        val vm = SettingsViewModel(supabase, tokenStore, cache, repository, appScope)
        

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
        val vm = SettingsViewModel(supabase, tokenStore, cache, repository, appScope)
        

        assertFalse(vm.state.value.isLoading)
        vm.viewModelScope.cancel()
    }

    @Test
    fun `updateSetting calls supabase and reloads`() = runTest {
        coEvery { supabase.serverTier() } returns "pro"
        coEvery { supabase.settings() } returns testSettings
        val vm = SettingsViewModel(supabase, tokenStore, cache, repository, appScope)
        

        vm.updateSetting("data_retention_days", 14)
        

        coVerify { supabase.updateSettings(any()) }
        vm.viewModelScope.cancel()
    }

    @Test
    fun `signOut clears all caches`() = runTest {
        coEvery { supabase.serverTier() } returns "free"
        coEvery { supabase.settings() } returns testSettings
        val vm = SettingsViewModel(supabase, tokenStore, cache, repository, appScope)
        

        vm.signOut()
        appDispatcher.scheduler.advanceUntilIdle()
        

        coVerify { supabase.revokeSession(any()) }
        coVerify { cache.clearDashboard() }
        coVerify { cache.clearProviders() }
        coVerify { cache.clearSessions() }
        coVerify { cache.clearAlerts() }
        coVerify { cache.clearDevices() }
        vm.viewModelScope.cancel()
    }

    @Test
    fun `signOut clears cache even when supabase throws`() = runTest {
        coEvery { supabase.serverTier() } returns "free"
        coEvery { supabase.settings() } returns testSettings
        coEvery { supabase.revokeSession(any()) } throws RuntimeException("network")
        val vm = SettingsViewModel(supabase, tokenStore, cache, repository, appScope)
        

        vm.signOut()
        appDispatcher.scheduler.advanceUntilIdle()
        

        // Cache should still be cleared
        coVerify { cache.clearDashboard() }
        vm.viewModelScope.cancel()
    }

    @Test
    fun `deleteAccount success reports deleteSuccess`() = runTest {
        coEvery { supabase.serverTier() } returns "free"
        coEvery { supabase.settings() } returns testSettings
        coEvery { supabase.deleteAccount() } returns Unit
        val vm = SettingsViewModel(supabase, tokenStore, cache, repository, appScope)

        vm.deleteAccount()

        assertTrue(vm.state.value.deleteSuccess)
        vm.viewModelScope.cancel()
    }

    @Test
    fun `deleteAccount failure sets deleteError`() = runTest {
        coEvery { supabase.serverTier() } returns "free"
        coEvery { supabase.settings() } returns testSettings
        coEvery { supabase.deleteAccount() } throws RuntimeException("server error")
        val vm = SettingsViewModel(supabase, tokenStore, cache, repository, appScope)
        

        vm.deleteAccount()

        assertFalse(vm.state.value.deleteSuccess)
        assertNotNull(vm.state.value.deleteError)
        assertEquals(
            UiError.ActionFailed(UiError.Action.DeleteAccount, UiError.Unknown("server error")),
            vm.state.value.deleteError,
        )
        vm.viewModelScope.cancel()
    }

    @Test
    fun `demo mode shows demo user info`() = runTest {
        every { tokenStore.isDemoMode } returns true
        coEvery { supabase.serverTier() } returns "free"
        coEvery { supabase.settings() } returns testSettings
        val vm = SettingsViewModel(supabase, tokenStore, cache, repository, appScope)

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
        val vm = SettingsViewModel(supabase, tokenStore, cache, repository, appScope)

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
    fun `exitDemoMode clears the flag, the token store and the shared repository`() = runTest {
        every { tokenStore.isDemoMode } returns true
        val vm = SettingsViewModel(supabase, tokenStore, cache, repository, appScope)

        vm.exitDemoMode()

        verify { tokenStore.isDemoMode = false }
        verify { tokenStore.clear() }
        verify { repository.exitDemoMode() }
        verify { supabase.clearDemoState() }
        vm.viewModelScope.cancel()
    }

    @Test
    fun `signOut ends the local session before the server call, with the token it had`() = runTest {
        // A real TokenStore: reading the token after clear() would hand the server null.
        val store = TokenStore(InMemorySharedPreferences())
        store.updateAuthState("access-1", "refresh-1", "user-1")
        coEvery { supabase.revokeSession(any()) } answers {
            assertNull("the session is gone before the server is called", store.accessToken)
        }
        val vm = SettingsViewModel(supabase, store, cache, repository, appScope)

        vm.signOut()
        appDispatcher.scheduler.advanceUntilIdle()

        assertNull(store.accessToken)
        coVerify { supabase.revokeSession("access-1") }
        coVerify { cache.clearDailyUsage() }
        vm.viewModelScope.cancel()
    }

    @Test
    fun `sign-out's work outlives the view model and does not wait on the network`() = runTest {
        every { tokenStore.accessToken } returns "access-1"
        coEvery { supabase.revokeSession(any()) } coAnswers { awaitCancellation() }
        // A wipe that suspends, as Room's does: on the view model's scope the cancel below
        // would stop it before daily usage is cleared.
        coEvery { cache.clearDashboard() } coAnswers { delay(1) }
        val vm = SettingsViewModel(supabase, tokenStore, cache, repository, appScope)

        vm.signOut()
        vm.viewModelScope.cancel() // the session's view models are cleared at once
        appDispatcher.scheduler.advanceUntilIdle()

        verify { tokenStore.clear() }
        verify { repository.resetSession() }
        coVerify { cache.clearDashboard() }
        coVerify { cache.clearDailyUsage() }
        coVerify { supabase.revokeSession("access-1") }
    }

    @Test
    fun `deleting the account removes it from the device too`() = runTest {
        val vm = SettingsViewModel(supabase, tokenStore, cache, repository, appScope)

        vm.deleteAccount()
        appDispatcher.scheduler.advanceUntilIdle()

        assertTrue(vm.state.value.deleteSuccess)
        coVerify { supabase.deleteAccount() }
        verify { tokenStore.clear() }
        verify { repository.resetSession() }
        coVerify { cache.clearDashboard() }
        coVerify { cache.clearDailyUsage() }
        vm.viewModelScope.cancel()
    }
}
