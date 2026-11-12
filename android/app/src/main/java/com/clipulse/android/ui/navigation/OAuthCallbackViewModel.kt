package com.clipulse.android.ui.navigation

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.clipulse.android.data.remote.OAuthCallbackResult
import com.clipulse.android.data.remote.OAuthDeepLinkCallback
import com.clipulse.android.data.remote.OAuthDeepLinkNotice
import com.clipulse.android.data.remote.OAuthDeepLinkOutcome
import com.clipulse.android.data.remote.OAuthDeepLinkRouter
import com.clipulse.android.data.remote.TokenStore
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.launch
import javax.inject.Inject

/**
 * Owns a browser round-trip's answer from the moment the pending flow is claimed until a
 * screen consumes the callback (or notice). Activity-scoped, so it outlives a configuration
 * change (a rotation), but not a process death:
 *
 *  - the claim runs in [viewModelScope], not in the Activity's lifecycle scope. The claim
 *    removes the pending record (on an IO thread); if it ran in the Activity's scope, a
 *    rotation while it was out would cancel it after the record was gone and before the
 *    callback was routed: the sign-in or link would be lost without a word;
 *  - the routed callback is held here until a screen consumes it, so a configuration change
 *    between routing and consumption delivers it to the new screen. A recreated Activity
 *    does not hand its old deep link over again (MainActivity.onCreate): there is nothing
 *    to add;
 *  - the record is handed out once, and only to the callback whose state it holds
 *    ([TokenStore.claimPendingOAuthFlow]): a second delivery of the same link claims
 *    nothing, so the callback is delivered exactly once, and an older flow's link, however
 *    it arrives, cannot take a newer flow's record (it used to: a spurious state mismatch,
 *    and the real callback then found nothing).
 *
 * Nothing here is saved for a process death: the PKCE verifier stays out of any
 * SavedStateHandle. A process death between the claim and the exchange needs a new sign-in,
 * as an exchange already in flight would.
 */
@HiltViewModel
class OAuthCallbackViewModel @Inject constructor(
    private val tokenStore: TokenStore,
) : ViewModel() {

    private val _callback = MutableStateFlow<OAuthDeepLinkCallback?>(null)

    /** A successful callback waiting for the screen of its kind. */
    val pendingCallback: StateFlow<OAuthDeepLinkCallback?> = _callback

    private val _notice = MutableStateFlow<OAuthDeepLinkNotice?>(null)

    /** A deep link that produced no callback (cancel, error, mismatch), for the screen of its kind. */
    val pendingNotice: StateFlow<OAuthDeepLinkNotice?> = _notice

    /** Claims the pending flow for [parsed] and routes it. Returns at once; the work is retained. */
    fun receive(parsed: OAuthCallbackResult) {
        viewModelScope.launch { route(parsed) }
    }

    /**
     * A successful callback claims the pending flow only if it is that flow's own (its state
     * matches); any other one is dropped and the pending flow stays for its real callback. A
     * cancel or an error carries no state: it is reported for the pending flow's kind, and
     * the flow is left in place (a new attempt replaces it; it expires on its own).
     */
    private suspend fun route(parsed: OAuthCallbackResult) {
        val pending = when (parsed) {
            is OAuthCallbackResult.Success -> tokenStore.claimPendingOAuthFlow(parsed.state)
            else -> tokenStore.peekPendingOAuthFlow()
        }
        when (val outcome = OAuthDeepLinkRouter.route(parsed = parsed, pending = pending)) {
            is OAuthDeepLinkOutcome.DeliverCallback -> _callback.value = outcome.callback
            is OAuthDeepLinkOutcome.DeliverNotice -> _notice.value = outcome.notice
            // Unsolicited, another flow's (stale) callback, or one already claimed: nothing to deliver.
            OAuthDeepLinkOutcome.Drop -> Unit
        }
    }

    /** The screen has taken the callback. */
    fun consumeCallback() {
        _callback.value = null
    }

    /** The screen has shown the notice. */
    fun consumeNotice() {
        _notice.value = null
    }
}
