package com.clipulse.android.ui.settings

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.clipulse.android.data.model.SettingsSnapshot
import com.clipulse.android.data.model.UserIdentity
import com.clipulse.android.data.remote.ApiError
import com.clipulse.android.data.remote.EndReason
import com.clipulse.android.data.remote.SupabaseClient
import com.clipulse.android.data.remote.TokenStore
import com.clipulse.android.data.session.SessionLifecycle
import com.clipulse.android.di.ApplicationScope
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.launch
import javax.inject.Inject
import com.clipulse.android.ui.common.UiError

data class SettingsUiState(
    val userName: String? = null,
    val userEmail: String? = null,
    val tier: String = "free",
    val settings: SettingsSnapshot? = null,
    val isLoading: Boolean = true,
    val deleteError: UiError? = null,
    val deleteSuccess: Boolean = false,
    val webhookEnabled: Boolean = false,
    val webhookUrl: String? = null,
    val webhookFilterSeverities: List<String> = emptyList(),
    val webhookFilterTypes: List<String> = emptyList(),
    val isDemoMode: Boolean = false,
    val linkedIdentities: List<UserIdentity> = emptyList(),
    val isLinkingIdentity: Boolean = false,
    val linkIdentityError: UiError? = null,
)

@HiltViewModel
class SettingsViewModel @Inject constructor(
    private val supabase: SupabaseClient,
    private val tokenStore: TokenStore,
    private val lifecycle: SessionLifecycle,
    @ApplicationScope private val appScope: CoroutineScope,
) : ViewModel() {

    private val _state = MutableStateFlow(
        SettingsUiState(
            // Demo mode's name is copy, rendered by SettingsScreen in the app's language.
            userName = if (tokenStore.isDemoMode) null else tokenStore.userName,
            userEmail = if (tokenStore.isDemoMode) "demo@clipulse.app" else tokenStore.userEmail,
            isDemoMode = tokenStore.isDemoMode,
        )
    )
    val state: StateFlow<SettingsUiState> = _state

    init {
        loadSettings()
        refreshLinkedIdentities()
    }

    // ── Identity linking ─────────────────────────────

    fun refreshLinkedIdentities() {
        if (tokenStore.isDemoMode) return
        viewModelScope.launch {
            try {
                val list = supabase.userIdentities()
                _state.value = _state.value.copy(linkedIdentities = list)
            } catch (e: Exception) {
                // Non-fatal — surface via linkIdentityError if something important failed
                _state.value = _state.value.copy(linkIdentityError = UiError.action(UiError.Action.LoadLinkedAccounts, e))
            }
        }
    }

    /**
     * Start a link-identity flow: fetch authorize URL, persist pending-flow record to survive
     * process death during the browser round-trip. Returns the URL to open or null on error.
     */
    suspend fun startLinkIdentity(provider: String): String? {
        _state.value = _state.value.copy(linkIdentityError = null)
        return try {
            val ctx = supabase.session() ?: throw ApiError.TokenExpired
            val (url, verifier, state) = supabase.linkIdentityAuthorizeUrl(provider, ctx)
            tokenStore.savePendingOAuthFlow(
                TokenStore.PendingOAuthFlow(
                    kind = "link",
                    provider = provider,
                    codeVerifier = verifier,
                    state = state,
                    createdAt = System.currentTimeMillis(),
                    // The callback completes the link for this session only.
                    sessionId = ctx.sessionId,
                )
            )
            url
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            _state.value = _state.value.copy(linkIdentityError = UiError.action(UiError.Action.StartLink, e))
            null
        }
    }

    fun completeLinkIdentity(code: String, codeVerifier: String, sessionId: String?) {
        viewModelScope.launch {
            _state.value = _state.value.copy(isLinkingIdentity = true, linkIdentityError = null)
            try {
                // MainActivity already claimed the pending-flow record.
                supabase.exchangeOAuthCodeForLink(code, codeVerifier, sessionId)
                val list = supabase.userIdentities()
                _state.value = _state.value.copy(isLinkingIdentity = false, linkedIdentities = list)
            } catch (e: Exception) {
                _state.value = _state.value.copy(
                    isLinkingIdentity = false,
                    linkIdentityError = UiError.action(UiError.Action.Link, e),
                )
            }
        }
    }

    fun unlinkIdentity(identity: UserIdentity) {
        viewModelScope.launch {
            _state.value = _state.value.copy(isLinkingIdentity = true, linkIdentityError = null)
            try {
                supabase.unlinkIdentity(identity.id)
                val list = supabase.userIdentities()
                _state.value = _state.value.copy(isLinkingIdentity = false, linkedIdentities = list)
            } catch (e: Exception) {
                _state.value = _state.value.copy(
                    isLinkingIdentity = false,
                    linkIdentityError = UiError.action(UiError.Action.Unlink, e),
                )
            }
        }
    }

    private fun loadSettings() {
        // Demo mode has no account settings: leaving `settings` null keeps the notification
        // and threshold cards, which only edit a real account, off the screen.
        if (tokenStore.isDemoMode) {
            _state.value = _state.value.copy(tier = "free", isLoading = false)
            return
        }
        viewModelScope.launch {
            try {
                val tier = supabase.serverTier()
                val settings = supabase.settings()
                val filter = settings?.webhookEventFilter
                _state.value = _state.value.copy(
                    tier = tier,
                    settings = settings,
                    isLoading = false,
                    webhookEnabled = settings?.webhookEnabled ?: false,
                    webhookUrl = settings?.webhookUrl,
                    webhookFilterSeverities = filter?.severities ?: emptyList(),
                    webhookFilterTypes = filter?.types ?: emptyList(),
                )
            } catch (_: Exception) {
                _state.value = _state.value.copy(isLoading = false)
            }
        }
    }

    fun updateSetting(key: String, value: Any) {
        viewModelScope.launch {
            try {
                val patch = org.json.JSONObject().apply { put(key, value) }
                supabase.updateSettings(patch)
                // Reload to reflect server state
                loadSettings()
            } catch (_: Exception) {
                // Silently fail — setting will revert on next load
            }
        }
    }

    /**
     * Ends demo mode through the same transition as any other end; the lifecycle empties the
     * repository's demo rows. Navigation follows the session state, not this call.
     */
    fun exitDemoMode() {
        val demo = tokenStore.snapshot()?.takeIf { it.isDemo }
        if (demo != null) lifecycle.endIfCurrent(demo.sessionId, EndReason.DemoExit)
        supabase.clearDemoState()
    }

    fun testWebhook() {
        viewModelScope.launch {
            try {
                supabase.testWebhook()
            } catch (_: Exception) {
                // Best-effort test
            }
        }
    }

    fun toggleWebhookFilterSeverity(severity: String) {
        val current = _state.value.webhookFilterSeverities.toMutableList()
        if (current.contains(severity)) current.remove(severity) else current.add(severity)
        _state.value = _state.value.copy(webhookFilterSeverities = current)
        pushWebhookFilter(current, _state.value.webhookFilterTypes)
    }

    fun toggleWebhookFilterType(type: String) {
        val current = _state.value.webhookFilterTypes.toMutableList()
        if (current.contains(type)) current.remove(type) else current.add(type)
        _state.value = _state.value.copy(webhookFilterTypes = current)
        pushWebhookFilter(_state.value.webhookFilterSeverities, current)
    }

    private fun pushWebhookFilter(severities: List<String>, types: List<String>) {
        viewModelScope.launch {
            try {
                val filterJson = org.json.JSONObject().apply {
                    if (severities.isNotEmpty()) put("severities", org.json.JSONArray(severities))
                    if (types.isNotEmpty()) put("types", org.json.JSONArray(types))
                }
                val patch = org.json.JSONObject().apply {
                    put("webhook_event_filter", if (severities.isEmpty() && types.isEmpty()) org.json.JSONObject.NULL else filterJson)
                }
                supabase.updateSettings(patch)
            } catch (_: Exception) { }
        }
    }

    fun signOut() {
        // End the session before anything else: the credentials and the teardown marker go
        // in one step, which also captures the token to revoke, so the revocation can never
        // use a rotated or a later account's token. The sign-in screen follows from the
        // session state.
        val ended = lifecycle.endCurrent(EndReason.UserSignedOut) ?: return
        val token = ended.accessToken
        // Revoking touches nothing on this device, so it cannot undo a sign-in that happens
        // while it is still running. The app's scope, not this view model's: the session's
        // view models are cleared as soon as the sign-in screen shows.
        appScope.launch {
            runCatching { supabase.revokeSession(token) }
        }
    }

    /**
     * Deletes the account of the session this tap was made in, then ends exactly that session
     * (the client already did; this is the backstop that also starts the on-device deletion).
     * The sign-in screen follows from the session state, not from `deleteSuccess`.
     */
    fun deleteAccount() {
        val session = tokenStore.snapshot() ?: return
        viewModelScope.launch {
            _state.value = _state.value.copy(isLoading = true, deleteError = null)
            try {
                supabase.deleteAccount(session)
                lifecycle.endIfCurrent(session.sessionId, EndReason.AccountDeleted)
                _state.value = _state.value.copy(isLoading = false, deleteSuccess = true)
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                _state.value = _state.value.copy(
                    isLoading = false,
                    deleteError = UiError.action(UiError.Action.DeleteAccount, e),
                )
            }
        }
    }
}
