package com.clipulse.android.ui.login

import com.clipulse.android.ui.common.UiError
import com.clipulse.android.MainDispatcherRule
import com.clipulse.android.data.model.AuthResponse
import com.clipulse.android.data.model.UserDTO
import com.clipulse.android.data.remote.ApiError
import com.clipulse.android.data.remote.InMemorySharedPreferences
import com.clipulse.android.data.remote.SupabaseClient
import com.clipulse.android.data.remote.TokenStore
import com.clipulse.android.data.local.FakeCacheDao
import com.clipulse.android.data.session.SessionLifecycle
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import io.mockk.coEvery
import io.mockk.coVerify
import io.mockk.every
import io.mockk.mockk
import io.mockk.verify
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.cancel
import androidx.lifecycle.viewModelScope
import kotlinx.coroutines.test.runTest
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test

@OptIn(ExperimentalCoroutinesApi::class)
class LoginViewModelTest {

    @get:Rule
    val mainDispatcherRule = MainDispatcherRule()

    private val supabase = mockk<SupabaseClient>(relaxed = true)
    private val tokenStore = mockk<TokenStore>(relaxed = true)
    private val lifecycle = mockk<SessionLifecycle>(relaxed = true)

    private fun vm(store: TokenStore = tokenStore, lc: SessionLifecycle = lifecycle) = LoginViewModel(supabase, store, lc)

    private fun auth(sessionId: String) = AuthResponse(
        access_token = "test-token",
        refresh_token = "test-refresh",
        user = UserDTO(id = "user-1", name = "Test User", email = "user-1@example.test"),
        paired = true,
        sessionId = sessionId,
    )

    @Test
    fun `initial state is the empty form`() = runTest {
        val vm = vm()
        assertNull(vm.state.value.completedSessionId)
        assertFalse(vm.state.value.isLoading)
        assertNull(vm.state.value.error)
        vm.viewModelScope.cancel()
    }

    @Test
    fun `signInWithGoogle completes with the session it installed`() = runTest {
        coEvery { supabase.signInWithGoogle("id-token", "Test User", "user-1@example.test") } returns auth("session-G")
        val vm = vm()

        vm.signInWithGoogle("id-token", "Test User", "user-1@example.test")

        assertEquals("session-G", vm.state.value.completedSessionId)
        assertFalse(vm.state.value.isLoading)
        assertNull(vm.state.value.error)
        vm.viewModelScope.cancel()
    }

    @Test
    fun `signInWithGoogle failure sets error`() = runTest {
        coEvery { supabase.signInWithGoogle(any(), any(), any()) } throws RuntimeException("invalid token")
        val vm = vm()

        vm.signInWithGoogle("bad-token", null, null)

        assertNull(vm.state.value.completedSessionId)
        assertEquals(UiError.Unknown("invalid token"), vm.state.value.error)
        vm.viewModelScope.cancel()
    }

    @Test
    fun `sendOTP success shows OTP input`() = runTest {
        coEvery { supabase.sendOTP("user-2@example.test") } returns Unit
        val vm = vm()

        vm.sendOTP("user-2@example.test")

        assertTrue(vm.state.value.showOtpInput)
        assertEquals("user-2@example.test", vm.state.value.otpEmail)
        vm.viewModelScope.cancel()
    }

    @Test
    fun `sendOTP failure sets error`() = runTest {
        coEvery { supabase.sendOTP(any()) } throws RuntimeException("rate limited")
        val vm = vm()

        vm.sendOTP("user-2@example.test")

        assertFalse(vm.state.value.showOtpInput)
        assertEquals(UiError.Unknown("rate limited"), vm.state.value.error)
        vm.viewModelScope.cancel()
    }

    @Test
    fun `verifyOTP completes with its session`() = runTest {
        coEvery { supabase.sendOTP(any()) } returns Unit
        coEvery { supabase.verifyOTP("user-2@example.test", "123456") } returns auth("session-O")
        val vm = vm()

        vm.sendOTP("user-2@example.test")
        vm.verifyOTP("123456")

        assertEquals("session-O", vm.state.value.completedSessionId)
        vm.viewModelScope.cancel()
    }

    @Test
    fun `signInWithPassword completes with its session`() = runTest {
        coEvery { supabase.signInWithPassword("user-1@example.test", "pass123") } returns auth("session-P")
        val vm = vm()

        vm.signInWithPassword("user-1@example.test", "pass123")

        assertEquals("session-P", vm.state.value.completedSessionId)
        vm.viewModelScope.cancel()
    }

    @Test
    fun `an OAuth exchange completes with its session, under the generation its flow started with`() = runTest {
        coEvery { supabase.exchangeOAuthCode("code-1", "verifier-1", 7L) } returns "session-X"
        val vm = vm()

        vm.exchangeOAuthCode("code-1", "verifier-1", 7L)

        assertEquals("session-X", vm.state.value.completedSessionId)
        vm.viewModelScope.cancel()
    }

    @Test
    fun `a sign-in a newer one overtook is not an error`() = runTest {
        coEvery { supabase.signInWithPassword(any(), any()) } throws ApiError.SessionSuperseded
        val vm = vm()

        vm.signInWithPassword("user-1@example.test", "pass123")

        assertNull(vm.state.value.error)
        assertNull(vm.state.value.completedSessionId)
        assertFalse(vm.state.value.isLoading)
        vm.viewModelScope.cancel()
    }

    @Test
    fun `an older attempt that answers last changes nothing`() = runTest {
        val olderAnswer = CompletableDeferred<AuthResponse>()
        coEvery { supabase.signInWithGoogle(any(), any(), any()) } coAnswers { olderAnswer.await() }
        coEvery { supabase.signInWithPassword(any(), any()) } returns auth("session-new")
        val vm = vm()

        vm.signInWithGoogle("id-token", null, null) // older, still out
        vm.signInWithPassword("user-1@example.test", "pass123") // newer, answers first
        assertEquals("session-new", vm.state.value.completedSessionId)

        olderAnswer.complete(auth("session-old"))
        assertEquals("session-new", vm.state.value.completedSessionId)

        vm.viewModelScope.cancel()
    }

    @Test
    fun `an older attempt's failure does not cover the newer result`() = runTest {
        val olderAnswer = CompletableDeferred<AuthResponse>()
        coEvery { supabase.signInWithGoogle(any(), any(), any()) } coAnswers { olderAnswer.await() }
        coEvery { supabase.signInWithPassword(any(), any()) } returns auth("session-new")
        val vm = vm()

        vm.signInWithGoogle("id-token", null, null)
        vm.signInWithPassword("user-1@example.test", "pass123")
        olderAnswer.completeExceptionally(RuntimeException("late failure"))

        assertNull(vm.state.value.error)
        assertEquals("session-new", vm.state.value.completedSessionId)
        vm.viewModelScope.cancel()
    }

    @Test
    fun `demo mode completes with its own synthetic session`() = runTest {
        val store = TokenStore(InMemorySharedPreferences())
        val realLifecycle = SessionLifecycle(
            store,
            FakeCacheDao(),
            CoroutineScope(SupervisorJob() + Dispatchers.Unconfined),
            Dispatchers.Unconfined,
        )
        val vm = vm(store, realLifecycle)

        vm.enterDemoMode()

        val id = vm.state.value.completedSessionId
        assertNotNull(id)
        assertTrue(id!!.startsWith(TokenStore.DEMO_ID_PREFIX))
        assertEquals(id, store.sessionId)
        assertTrue(store.isDemoMode)
        vm.viewModelScope.cancel()
    }

    @Test
    fun `the sign-in screen never ends a session`() = runTest {
        coEvery { supabase.signInWithPassword(any(), any()) } throws ApiError.TokenExpired
        val vm = vm()

        vm.signInWithPassword("user-1@example.test", "pass123")

        verify(exactly = 0) { tokenStore.endIfCurrent(any(), any()) }
        verify(exactly = 0) { tokenStore.endCurrent(any()) }
        coVerify(exactly = 0) { lifecycle.endIfCurrent(any(), any()) }
        coVerify(exactly = 0) { lifecycle.endCurrent(any()) }
        vm.viewModelScope.cancel()
    }

    @Test
    fun `a browser sign-in starts a new generation saved with its flow`() = runTest {
        val vm = vm()
        every { supabase.oauthAuthorizeUrl("github") } returns Triple("https://example.test/authorize", "verifier-1", "state-1")

        vm.startOAuthLogin("github")

        verify(exactly = 1) { tokenStore.beginOAuthLogin(match { it.kind == "login" && it.state == "state-1" }) }
        verify(exactly = 0) { tokenStore.savePendingOAuthFlow(any()) }
        vm.viewModelScope.cancel()
    }
}
