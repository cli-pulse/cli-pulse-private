package com.clipulse.android.ui.login

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.clipulse.android.data.remote.ApiError
import com.clipulse.android.data.remote.SupabaseClient
import com.clipulse.android.data.remote.TokenStore
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.launch
import javax.inject.Inject
import com.clipulse.android.ui.common.UiError

data class LoginUiState(
    val isLoading: Boolean = false,
    val error: UiError? = null,
    /**
     * The session a sign-in on this screen installed. The screen hands it to the gate, which
     * shows the tabs only if it is still the current session. Not a Boolean: "signed in" says
     * nothing about WHICH session, and A -> signed out -> B would look the same as A.
     */
    val completedSessionId: String? = null,
    val showOtpInput: Boolean = false,
    val otpEmail: String = "",
)

/**
 * The sign-in form. It does not restore saved sessions (SessionGateViewModel does, once per
 * session, in the Activity's scope) and never clears credentials: a session ends only through
 * TokenStore.endIfCurrent.
 */
@HiltViewModel
class LoginViewModel @Inject constructor(
    private val supabase: SupabaseClient,
    private val tokenStore: TokenStore,
) : ViewModel() {

    private val _state = MutableStateFlow(LoginUiState())
    val state: StateFlow<LoginUiState> = _state

    /** The latest sign-in attempt started here; an older one's result is dropped (main thread only). */
    private var attempt = 0

    /**
     * Runs one sign-in attempt. Only the latest attempt may change the screen: an older one
     * that answers last neither completes nor shows its error. [ApiError.SessionSuperseded]
     * (a newer sign-in won in the client) is not an error.
     */
    private fun signIn(work: suspend () -> String) {
        val mine = ++attempt
        _state.value = _state.value.copy(isLoading = true, error = null)
        viewModelScope.launch {
            try {
                val sessionId = work()
                if (mine == attempt) {
                    _state.value = _state.value.copy(isLoading = false, completedSessionId = sessionId)
                }
            } catch (e: CancellationException) {
                throw e
            } catch (e: ApiError.SessionSuperseded) {
                if (mine == attempt) _state.value = _state.value.copy(isLoading = false)
            } catch (e: Exception) {
                if (mine == attempt) _state.value = _state.value.copy(isLoading = false, error = UiError.from(e))
            }
        }
    }

    private fun installed(sessionId: String?): String = sessionId ?: throw ApiError.SessionSuperseded

    fun signInWithGoogle(idToken: String, name: String?, email: String?) =
        signIn { installed(supabase.signInWithGoogle(idToken, name, email).sessionId) }

    fun sendOTP(email: String) {
        viewModelScope.launch {
            _state.value = _state.value.copy(isLoading = true, error = null)
            try {
                supabase.sendOTP(email)
                _state.value = _state.value.copy(
                    isLoading = false,
                    showOtpInput = true,
                    otpEmail = email,
                )
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                _state.value = _state.value.copy(isLoading = false, error = UiError.from(e))
            }
        }
    }

    fun verifyOTP(code: String) {
        val email = _state.value.otpEmail
        signIn { installed(supabase.verifyOTP(email, code).sessionId) }
    }

    fun signInWithPassword(email: String, password: String) =
        signIn { installed(supabase.signInWithPassword(email, password).sessionId) }

    /**
     * Start a login OAuth flow: build the Supabase authorize URL and persist the pending-flow
     * record (kind/provider/verifier/state) so we survive process death during the browser
     * round-trip. Returns the URL to open.
     */
    fun startOAuthLogin(provider: String): String {
        val (url, verifier, state) = supabase.oauthAuthorizeUrl(provider)
        tokenStore.savePendingOAuthFlow(
            TokenStore.PendingOAuthFlow(
                kind = "login",
                provider = provider,
                codeVerifier = verifier,
                state = state,
                createdAt = System.currentTimeMillis(),
            )
        )
        return url
    }

    /** Exchange an OAuth authorization code obtained via deep link (MainActivity claimed the record). */
    fun exchangeOAuthCode(code: String, codeVerifier: String) =
        signIn { supabase.exchangeOAuthCode(code, codeVerifier) }

    /** Demo mode is a session of its own, with a synthetic id; it needs no check. */
    fun enterDemoMode() {
        ++attempt
        val sessionId = tokenStore.enterDemoMode()
        _state.value = _state.value.copy(isLoading = false, error = null, completedSessionId = sessionId)
    }
}
