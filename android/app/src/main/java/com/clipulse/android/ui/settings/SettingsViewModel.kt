package com.clipulse.android.ui.settings

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.clipulse.android.data.model.SettingsSnapshot
import com.clipulse.android.data.model.UserIdentity
import com.clipulse.android.data.remote.ApiError
import com.clipulse.android.data.remote.EndReason
import com.clipulse.android.data.remote.SessionContext
import com.clipulse.android.data.remote.SupabaseClient
import com.clipulse.android.data.remote.TokenStore
import com.clipulse.android.data.session.SessionLifecycle
import com.clipulse.android.di.ApplicationScope
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.async
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
    val webhookEnabled: Boolean = false,
    val webhookUrl: String? = null,
    val webhookFilterSeverities: List<String> = emptyList(),
    val webhookFilterTypes: List<String> = emptyList(),
    val isDemoMode: Boolean = false,
    val linkedIdentities: List<UserIdentity> = emptyList(),
    val isLinkingIdentity: Boolean = false,
    val linkIdentityError: UiError? = null,
)

/**
 * Settings for ONE session: the one current when the view model was created ([owner]).
 * Every call it makes, destructive ones included, runs for that session and ends only that
 * session (`endIfCurrent(owner)`): if another account has signed in by the time a queued
 * tap runs, the tap does nothing to it. The gate drops this view model when the session
 * changes, but asynchronously, so the ownership check cannot rely on that.
 */
@HiltViewModel
class SettingsViewModel @Inject constructor(
    private val supabase: SupabaseClient,
    private val tokenStore: TokenStore,
    private val lifecycle: SessionLifecycle,
    @ApplicationScope private val appScope: CoroutineScope,
) : ViewModel() {

    /** The session this screen belongs to; null if it opened with none (it then does nothing). */
    private val owner: SessionContext? = tokenStore.snapshot()
    private val isDemo = owner?.isDemo == true

    private val _state = MutableStateFlow(
        SettingsUiState(
            // Demo mode's name is copy, rendered by SettingsScreen in the app's language.
            userName = if (isDemo) null else tokenStore.userName,
            userEmail = if (isDemo) "demo@clipulse.app" else tokenStore.userEmail,
            isDemoMode = isDemo,
        )
    )
    val state: StateFlow<SettingsUiState> = _state

    init {
        loadSettings()
        refreshLinkedIdentities()
    }

    // ── Identity linking ─────────────────────────────

    fun refreshLinkedIdentities() {
        val session = owner?.takeIf { !it.isDemo } ?: return
        viewModelScope.launch {
            try {
                val list = supabase.userIdentities(session)
                _state.value = _state.value.copy(linkedIdentities = list)
            } catch (e: CancellationException) {
                throw e
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
            val session = owner ?: throw ApiError.TokenExpired
            val (url, verifier, state) = supabase.linkIdentityAuthorizeUrl(provider, session)
            tokenStore.savePendingOAuthFlow(
                TokenStore.PendingOAuthFlow(
                    kind = "link",
                    provider = provider,
                    codeVerifier = verifier,
                    state = state,
                    createdAt = System.currentTimeMillis(),
                    // The callback completes the link for this session only.
                    sessionId = session.sessionId,
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

    /**
     * Completes a link for the session the flow belongs to ([sessionId], bound when
     * MainActivity claimed the flow); null means the flow could not be bound and is ignored.
     */
    fun completeLinkIdentity(code: String, codeVerifier: String, sessionId: String?) {
        if (sessionId == null) return
        viewModelScope.launch {
            _state.value = _state.value.copy(isLinkingIdentity = true, linkIdentityError = null)
            try {
                supabase.exchangeOAuthCodeForLink(code, codeVerifier, sessionId)
                val list = supabase.userIdentities(tokenStore.snapshotIfCurrent(sessionId) ?: throw ApiError.SessionSuperseded)
                _state.value = _state.value.copy(isLinkingIdentity = false, linkedIdentities = list)
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                _state.value = _state.value.copy(
                    isLinkingIdentity = false,
                    linkIdentityError = UiError.action(UiError.Action.Link, e),
                )
            }
        }
    }

    fun unlinkIdentity(identity: UserIdentity) {
        val session = owner ?: return
        viewModelScope.launch {
            _state.value = _state.value.copy(isLinkingIdentity = true, linkIdentityError = null)
            try {
                supabase.unlinkIdentity(identity.id, session)
                val list = supabase.userIdentities(session)
                _state.value = _state.value.copy(isLinkingIdentity = false, linkedIdentities = list)
            } catch (e: CancellationException) {
                throw e
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
        val session = owner
        if (session == null || session.isDemo) {
            _state.value = _state.value.copy(tier = "free", isLoading = false)
            return
        }
        viewModelScope.launch {
            try {
                val tier = supabase.serverTier(session)
                val settings = supabase.settings(session)
                val filter = settings.webhookEventFilter
                _state.value = _state.value.copy(
                    tier = tier,
                    settings = settings,
                    isLoading = false,
                    webhookEnabled = settings.webhookEnabled,
                    webhookUrl = settings.webhookUrl,
                    webhookFilterSeverities = filter?.severities ?: emptyList(),
                    webhookFilterTypes = filter?.types ?: emptyList(),
                )
            } catch (e: CancellationException) {
                throw e
            } catch (_: Exception) {
                _state.value = _state.value.copy(isLoading = false)
            }
        }
    }

    fun updateSetting(key: String, value: Any) {
        val session = owner ?: return
        viewModelScope.launch {
            try {
                val patch = org.json.JSONObject().apply { put(key, value) }
                supabase.updateSettings(patch, session)
                // Reload to reflect server state
                loadSettings()
            } catch (e: CancellationException) {
                throw e
            } catch (_: Exception) {
                // Silently fail — setting will revert on next load
            }
        }
    }

    /**
     * Ends demo mode through the same transition as any other end, for this screen's demo
     * session only; the lifecycle empties the repository's demo rows. Navigation follows the
     * session state, not this call.
     */
    fun exitDemoMode() {
        val demo = owner?.takeIf { it.isDemo } ?: return
        supabase.clearDemoState()
        appScope.launch {
            lifecycle.endIfCurrent(demo.sessionId, EndReason.DemoExit)
        }
    }

    fun testWebhook() {
        val session = owner ?: return
        viewModelScope.launch {
            try {
                supabase.testWebhook(session)
            } catch (e: CancellationException) {
                throw e
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
        val session = owner ?: return
        viewModelScope.launch {
            try {
                val filterJson = org.json.JSONObject().apply {
                    if (severities.isNotEmpty()) put("severities", org.json.JSONArray(severities))
                    if (types.isNotEmpty()) put("types", org.json.JSONArray(types))
                }
                val patch = org.json.JSONObject().apply {
                    put("webhook_event_filter", if (severities.isEmpty() && types.isEmpty()) org.json.JSONObject.NULL else filterJson)
                }
                supabase.updateSettings(patch, session)
            } catch (e: CancellationException) {
                throw e
            } catch (_: Exception) { }
        }
    }

    /**
     * Ends THIS screen's session (never one that signed in since), then ends that session, and
     * only that one, on the server (`scope=local`: the account's other devices stay signed in)
     * with exactly what the end removed: the pair captured in the same commit, so the
     * revocation can never use a rotated pair, half of two pairs, or a later account's. Both
     * run in the app's scope: the session's view models are cleared as soon as the sign-in
     * screen shows. Revoking touches nothing on this device, so it cannot undo a sign-in that
     * happens while it is still running.
     */
    fun signOut() {
        val session = owner?.takeIf { !it.isDemo } ?: return
        appScope.launch {
            val ended = lifecycle.endIfCurrent(session.sessionId, EndReason.UserSignedOut) ?: return@launch
            try {
                supabase.revokeSession(ended)
            } catch (e: CancellationException) {
                throw e
            } catch (_: Exception) {
                // Best effort: the session has already ended on this phone.
            }
        }
    }

    /**
     * Deletes the account of THIS screen's session. The client only asks the server; once it
     * confirms, the same job ends exactly that session, which deletes what the phone keeps for
     * it. The sign-in screen follows from the session state.
     *
     * The request and the end run in the app's scope, not this screen's: leaving Settings (or
     * the end itself closing it) while the request is out must not leave the phone signed in
     * to an account the server has deleted. This screen only shows the outcome, if it is
     * still there.
     *
     * Bound to the session of the tap: if another account signed in while the request was
     * out, the answer does nothing to it and shows nothing (an answer that arrives after the
     * switch is refused by the client the same way, as a superseded operation, which shows no
     * error).
     *
     * A failed or unconfirmed request causes no deletion-specific teardown on the phone, and
     * is reported. That includes a deletion the server carried out whose answer never arrived:
     * the phone stays signed in until its next request, which the server refuses
     * (`user_not_found`), and that ends the session (D1). The one session end that can happen
     * while the request is out is the client's own: the server definitively refused the
     * session. That session is then over, and it is reported as such, not as a failed deletion.
     */
    fun deleteAccount() {
        val session = owner?.takeIf { !it.isDemo } ?: return
        viewModelScope.launch {
            _state.value = _state.value.copy(isLoading = true, deleteError = null)
            val deletion = appScope.async {
                supabase.deleteAccount(session)
                lifecycle.endIfCurrent(session.sessionId, EndReason.AccountDeleted)
            }
            try {
                deletion.await()
                _state.value = _state.value.copy(isLoading = false)
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                _state.value = _state.value.copy(
                    isLoading = false,
                    deleteError = if (e is ApiError.TokenExpired) {
                        UiError.from(e)
                    } else {
                        UiError.action(UiError.Action.DeleteAccount, e)
                    },
                )
            }
        }
    }
}
