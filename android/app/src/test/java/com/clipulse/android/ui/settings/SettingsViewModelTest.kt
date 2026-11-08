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
        val vm = SettingsViewModel(supabase, tokenStore, cache, repository)

        assertEquals("Jason", vm.state.value.userName)
        assertEquals("jason@test.com", vm.state.value.userEmail)
        vm.viewModelScope.cancel()
    }

    @Test
    fun `loadSettings populates tier and settings`() = runTest {
        coEvery { supabase.serverTier() } returns "pro"
        coEvery { supabase.settings() } returns testSettings
        val vm = SettingsViewModel(supabase, tokenStore, cache, repository)
        

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
        val vm = SettingsViewModel(supabase, tokenStore, cache, repository)
        

        assertFalse(vm.state.value.isLoading)
        vm.viewModelScope.cancel()
    }

    @Test
    fun `updateSetting calls supabase and reloads`() = runTest {
        coEvery { supabase.serverTier() } returns "pro"
        coEvery { supabase.settings() } returns testSettings
        val vm = SettingsViewModel(supabase, tokenStore, cache, repository)
        

        vm.updateSetting("data_retention_days", 14)
        

        coVerify { supabase.updateSettings(any()) }
        vm.viewModelScope.cancel()
    }

    @Test
    fun `signOut clears all caches`() = runTest {
        coEvery { supabase.serverTier() } returns "free"
        coEvery { supabase.settings() } returns testSettings
        val vm = SettingsViewModel(supabase, tokenStore, cache, repository)
        

        vm.signOut()
        

        coVerify { supabase.signOut(any()) }
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
        coEvery { supabase.signOut(any()) } throws RuntimeException("network")
        val vm = SettingsViewModel(supabase, tokenStore, cache, repository)
        

        vm.signOut()
        

        // Cache should still be cleared
        coVerify { cache.clearDashboard() }
        vm.viewModelScope.cancel()
    }

    @Test
    fun `deleteAccount success calls onSuccess`() = runTest {
        coEvery { supabase.serverTier() } returns "free"
        coEvery { supabase.settings() } returns testSettings
        coEvery { supabase.deleteAccount() } returns Unit
        val vm = SettingsViewModel(supabase, tokenStore, cache, repository)
        

        var called = false
        vm.deleteAccount { called = true }
        

        assertTrue(called)
        assertTrue(vm.state.value.deleteSuccess)
        vm.viewModelScope.cancel()
    }

    @Test
    fun `deleteAccount failure sets deleteError`() = runTest {
        coEvery { supabase.serverTier() } returns "free"
        coEvery { supabase.settings() } returns testSettings
        coEvery { supabase.deleteAccount() } throws RuntimeException("server error")
        val vm = SettingsViewModel(supabase, tokenStore, cache, repository)
        

        vm.deleteAccount {}
        

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
        val vm = SettingsViewModel(supabase, tokenStore, cache, repository)

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
        val vm = SettingsViewModel(supabase, tokenStore, cache, repository)

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
        val vm = SettingsViewModel(supabase, tokenStore, cache, repository)

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
        coEvery { supabase.signOut(any()) } answers {
            assertNull("the session is gone before the server is called", store.accessToken)
        }
        val vm = SettingsViewModel(supabase, store, cache, repository)

        vm.signOut()

        assertNull(store.accessToken)
        coVerify { supabase.signOut("access-1") }
        vm.viewModelScope.cancel()
    }
}
