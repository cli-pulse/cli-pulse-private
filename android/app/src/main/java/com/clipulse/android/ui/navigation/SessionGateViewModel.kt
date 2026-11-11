package com.clipulse.android.ui.navigation

import androidx.lifecycle.SavedStateHandle
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.clipulse.android.data.remote.ApiError
import com.clipulse.android.data.remote.EndReason
import com.clipulse.android.data.remote.SessionState
import com.clipulse.android.data.remote.SupabaseClient
import com.clipulse.android.data.remote.TokenStore
import com.clipulse.android.data.session.SessionLifecycle
import com.clipulse.android.ui.common.UiError
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.launch
import java.io.IOException
import javax.inject.Inject

enum class GateScreen {
    /** The sign-in form. */
    Login,

    /** A saved session is being checked with the server; the sign-in screen shows a spinner. */
    Restoring,

    /** The signed-in (or demo) tabs. */
    Tabs,
}

/**
 * What the app shows, for which session. [activeSessionId] is the session the tabs (or the
 * restore) belong to; [epoch] numbers the signed-in sessions this Activity has shown, and keys
 * the tabs' view-model store and the sign-in screen's view model.
 */
data class GateState(
    val screen: GateScreen,
    val activeSessionId: String?,
    val epoch: Int,
    /** Shown on the sign-in screen after the server refused the last session. */
    val notice: UiError? = null,
    /** What the last restore ran into while keeping the session (offline, a server error). */
    val restoreError: UiError? = null,
)

/**
 * The one place that decides between the sign-in screen and the tabs, from the session
 * IDENTITY in [TokenStore.state], not from a "signed in" Boolean: A -> signed out -> B, and A
 * -> B with no signed-out state observed in between, are both a change of session.
 *
 * Rules:
 *  - the tabs show only while [GateState.activeSessionId] is the current session id;
 *  - when the current session changes or ends while the tabs show, the epoch moves on ONCE and
 *    the tabs' view models are dropped ([SessionViewModelStores.endSession]); this is the only
 *    place that does either, so a sign-out tap and the state change it causes cannot count twice;
 *  - a session found at start (or that replaced the one on the tabs) is checked with `me()`
 *    once, in this Activity-scoped view model: a rotation keeps the job, so it is not checked
 *    again; a refusal ends it through [SessionLifecycle], a network or server error keeps it;
 *  - a sign-in completes through [onLoggedIn] with the session id it installed; a stale
 *    completion (that session is no longer current) is ignored;
 *  - after a process death the state comes back from [SavedStateHandle] with no job: a saved
 *    "restoring" restarts the check once, a saved "tabs" stays (its first request validates),
 *    and either one whose session is gone falls back to the sign-in screen.
 */
@HiltViewModel
class SessionGateViewModel @Inject constructor(
    private val handle: SavedStateHandle,
    private val tokenStore: TokenStore,
    private val supabase: SupabaseClient,
    private val lifecycle: SessionLifecycle,
) : ViewModel() {

    /** The tabs' view-model stores, one per epoch; owned here so only this class ends them. */
    internal val sessionStores = SessionViewModelStores()

    private val _state = MutableStateFlow(initialState())
    val state: StateFlow<GateState> = _state

    private var restoreJob: Job? = null
    private var restoringFor: String? = null

    init {
        persist(_state.value)
        viewModelScope.launch {
            tokenStore.state.collect { onSessionState(it) }
        }
        // A fresh start with a saved session, or a "restoring" that a process death saved
        // without its job: check it (once; the job lives as long as this view model).
        val start = _state.value
        if (start.screen == GateScreen.Restoring && start.activeSessionId == tokenStore.state.value.sessionId) {
            startRestore(start.activeSessionId!!)
        }
    }

    /** A sign-in on the sign-in screen installed [sessionId]. */
    fun onLoggedIn(sessionId: String) {
        val current = tokenStore.state.value
        if (current.sessionId != sessionId) return // a stale completion: that session is gone
        val now = _state.value
        if (now.screen == GateScreen.Tabs && now.activeSessionId == sessionId) return
        cancelRestore()
        var epoch = now.epoch
        if (now.screen == GateScreen.Tabs) {
            sessionStores.endSession()
            epoch++
        }
        update(GateState(GateScreen.Tabs, sessionId, epoch))
    }

    private fun onSessionState(session: SessionState) {
        val now = _state.value
        if (session.sessionId == now.activeSessionId) return
        var epoch = now.epoch
        if (now.screen == GateScreen.Tabs) {
            sessionStores.endSession()
            epoch++
        }
        cancelRestore()
        val id = session.sessionId
        val next = when {
            id == null -> GateState(
                GateScreen.Login,
                null,
                epoch,
                notice = if (session.endedReason == EndReason.SessionRefused || session.endedReason == EndReason.SessionGone) {
                    UiError.SessionExpired
                } else {
                    null
                },
            )
            session.isDemo -> GateState(GateScreen.Tabs, id, epoch)
            // A sign-in on the sign-in screen: it completes through onLoggedIn once its
            // profile is in, so it is not checked again here.
            now.screen == GateScreen.Login -> GateState(GateScreen.Login, null, epoch)
            // The session on the tabs (or being checked) was replaced: check the new one.
            else -> GateState(GateScreen.Restoring, id, epoch)
        }
        update(next)
        if (next.screen == GateScreen.Restoring) startRestore(id!!)
    }

    private fun startRestore(sessionId: String) {
        if (restoringFor == sessionId && restoreJob?.isActive == true) return
        restoreJob?.cancel()
        restoringFor = sessionId
        restoreJob = viewModelScope.launch {
            // The state collector handles a session that is already gone.
            val session = tokenStore.snapshotIfCurrent(sessionId) ?: return@launch
            val error: UiError? = try {
                supabase.me(session)
                null
            } catch (e: CancellationException) {
                throw e
            } catch (e: ApiError.SessionSuperseded) {
                return@launch
            } catch (e: ApiError.TokenExpired) {
                // The client has already ended it if the server refused it; this is the
                // idempotent backstop (e.g. a session with no tokens left). Never a direct wipe.
                lifecycle.endIfCurrent(sessionId, EndReason.SessionRefused)
                return@launch
            } catch (e: IOException) {
                UiError.OfflineUsingCachedSession
            } catch (e: ApiError.Http) {
                if (e.code == 408 || e.code == 429 || e.code >= 500) UiError.OfflineUsingCachedSession else UiError.from(e)
            } catch (e: Exception) {
                UiError.from(e)
            }
            val now = _state.value
            if (now.screen == GateScreen.Restoring && now.activeSessionId == sessionId) {
                update(now.copy(screen = GateScreen.Tabs, restoreError = error))
            }
        }
    }

    private fun cancelRestore() {
        restoreJob?.cancel()
        restoreJob = null
        restoringFor = null
    }

    private fun update(next: GateState) {
        _state.value = next
        persist(next)
    }

    private fun persist(state: GateState) {
        handle[KEY_SCREEN] = state.screen.name
        handle[KEY_SESSION] = state.activeSessionId
        handle[KEY_EPOCH] = state.epoch
        handle[KEY_EXPIRED_NOTICE] = state.notice == UiError.SessionExpired
    }

    /** Fresh start, or the state a process death saved, reconciled with the session now stored. */
    private fun initialState(): GateState {
        val current = tokenStore.state.value
        val savedScreen = handle.get<String>(KEY_SCREEN)?.let { name ->
            GateScreen.entries.firstOrNull { it.name == name }
        }
        val savedSession = handle.get<String>(KEY_SESSION)
        val savedEpoch = handle.get<Int>(KEY_EPOCH) ?: 0
        // The "session expired" notice survives a process death with the sign-in screen.
        val savedNotice = if (handle.get<Boolean>(KEY_EXPIRED_NOTICE) == true) UiError.SessionExpired else null
        val id = current.sessionId
        val sameTabs = savedScreen == GateScreen.Tabs && savedSession == id
        // Tabs that were shown for a session that is not the current one count as ended.
        val epoch = if (savedScreen == GateScreen.Tabs && !sameTabs) savedEpoch + 1 else savedEpoch
        return when {
            id == null -> GateState(GateScreen.Login, null, epoch, notice = savedNotice)
            sameTabs -> GateState(GateScreen.Tabs, id, epoch)
            current.isDemo -> GateState(GateScreen.Tabs, id, epoch)
            else -> GateState(GateScreen.Restoring, id, epoch)
        }
    }

    override fun onCleared() {
        sessionStores.clear()
    }

    internal companion object {
        const val KEY_SCREEN = "session_gate_screen"
        const val KEY_SESSION = "session_gate_session"
        const val KEY_EPOCH = "session_gate_epoch"
        const val KEY_EXPIRED_NOTICE = "session_gate_expired_notice"
    }
}
