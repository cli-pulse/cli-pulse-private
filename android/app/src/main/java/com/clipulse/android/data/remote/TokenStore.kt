package com.clipulse.android.data.remote

import android.content.Context
import android.content.SharedPreferences
import androidx.security.crypto.EncryptedSharedPreferences
import androidx.security.crypto.MasterKey
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import java.util.UUID

/**
 * The encrypted credential store, and the ONE place a session starts, changes or ends.
 *
 * Every mutator runs under this object's monitor and writes in a single
 * `SharedPreferences.Editor` transaction, then publishes [state]. A session is identified
 * by a random `sessionId` written with its credentials; operations hold a [SessionContext]
 * and every write that belongs to a session is conditional on that session still being the
 * current one ([rotateIfCurrent], [setProfileIfCurrent], [setDeviceIdIfCurrent],
 * [endIfCurrent]).
 *
 * Writes use `apply()`, as before: the in-memory map changes synchronously (that is what the
 * next read sees), the disk write is asynchronous. A process killed within milliseconds of a
 * transaction loses the whole transaction, never half of it.
 */
class TokenStore internal constructor(
    private val prefs: SharedPreferences,
) {
    constructor(context: Context) : this(
        EncryptedSharedPreferences.create(
            context,
            "cli_pulse_secure_prefs",
            MasterKey.Builder(context).setKeyScheme(MasterKey.KeyScheme.AES256_GCM).build(),
            EncryptedSharedPreferences.PrefKeyEncryptionScheme.AES256_SIV,
            EncryptedSharedPreferences.PrefValueEncryptionScheme.AES256_GCM,
        ),
    )

    /** Why the last session ended, until the next one starts. In memory only. */
    private var lastEndReason: EndReason? = null

    private val _state = MutableStateFlow(readStateLocked())

    /** The current session id and teardown marker, re-published after every change. */
    val state: StateFlow<SessionState> get() = _state

    // ── Reads ─────────────────────────────────────────────────────────────

    val accessToken: String? get() = prefs.getString(KEY_ACCESS_TOKEN, null)

    val refreshToken: String? get() = prefs.getString(KEY_REFRESH_TOKEN, null)

    val userId: String? get() = prefs.getString(KEY_USER_ID, null)

    val userName: String? get() = prefs.getString(KEY_USER_NAME, null)

    val userEmail: String? get() = prefs.getString(KEY_USER_EMAIL, null)

    val deviceId: String? get() = prefs.getString(KEY_DEVICE_ID, null)

    val isDemoMode: Boolean get() = prefs.getBoolean(KEY_DEMO_MODE, false)

    val isLoggedIn: Boolean get() = isDemoMode || !accessToken.isNullOrBlank()

    /** A signed-in account, as opposed to demo mode or signed out. */
    val hasSession: Boolean get() = !isDemoMode && !accessToken.isNullOrBlank()

    /** The current session's id, or null when signed out. */
    val sessionId: String?
        @Synchronized get() = currentSessionIdLocked()

    /** The id of an ended session whose on-device data still has to be deleted. */
    val teardownPending: String?
        @Synchronized get() = prefs.getString(KEY_TEARDOWN_PENDING, null)

    /** The current session in one read: id, tokens and user together, or null when signed out. */
    @Synchronized
    fun snapshot(): SessionContext? = snapshotLocked()

    /** [snapshot], but only while [sessionId] is still the current session. */
    @Synchronized
    fun snapshotIfCurrent(sessionId: String): SessionContext? =
        snapshotLocked()?.takeIf { it.sessionId == sessionId }

    /** The device row registered for [sessionId], if that session is still the current one. */
    @Synchronized
    fun deviceIdFor(sessionId: String): String? =
        if (currentSessionIdLocked() == sessionId) prefs.getString(KEY_DEVICE_ID, null) else null

    // ── Session transitions ───────────────────────────────────────────────

    /**
     * Installs a signed-in session with a fresh id, in one transaction. [attemptOk] is
     * evaluated under the monitor, so the client can refuse a sign-in attempt that a newer
     * one has overtaken without a window between the check and the write; null means it
     * refused and nothing was written.
     *
     * Ends demo mode, forgets the previous session's device row and every pending OAuth
     * flow (an abandoned browser sign-in must not complete over this session later). If a
     * session was current, its id becomes the teardown marker, so its cached rows are deleted
     * before this session writes any.
     */
    @Synchronized
    fun installSession(
        accessToken: String?,
        refreshToken: String?,
        userId: String?,
        userName: String? = null,
        userEmail: String? = null,
        attemptOk: () -> Boolean = { true },
    ): String? {
        require(!accessToken.isNullOrBlank() || !refreshToken.isNullOrBlank()) { "a session needs a token" }
        if (!attemptOk()) return null
        val previous = currentSessionIdLocked()
        val id = UUID.randomUUID().toString()
        val edit = prefs.edit()
            .putString(KEY_ACCESS_TOKEN, accessToken)
            .putString(KEY_REFRESH_TOKEN, refreshToken)
            .putString(KEY_USER_ID, userId)
            .putString(KEY_USER_NAME, userName)
            .putString(KEY_USER_EMAIL, userEmail)
            .putString(KEY_SESSION_ID, id)
            .putBoolean(KEY_DEMO_MODE, false)
            .remove(KEY_DEVICE_ID)
        removePendingFlow(edit)
        if (previous != null) edit.putString(KEY_TEARDOWN_PENDING, previous)
        edit.apply()
        lastEndReason = null
        publishLocked()
        return id
    }

    /**
     * Demo mode as a session of its own: the flag and a synthetic `demo-<uuid>` id in one
     * transaction, so leaving it is the same [endIfCurrent] as any other end.
     */
    @Synchronized
    fun enterDemoMode(): String {
        val previous = currentSessionIdLocked()
        if (previous != null && prefs.getBoolean(KEY_DEMO_MODE, false)) return previous
        val id = DEMO_ID_PREFIX + UUID.randomUUID().toString()
        val edit = prefs.edit()
            .putBoolean(KEY_DEMO_MODE, true)
            .putString(KEY_SESSION_ID, id)
        if (previous != null) {
            edit.remove(KEY_ACCESS_TOKEN).remove(KEY_REFRESH_TOKEN).remove(KEY_USER_ID)
                .remove(KEY_USER_NAME).remove(KEY_USER_EMAIL).remove(KEY_DEVICE_ID)
                .putString(KEY_TEARDOWN_PENDING, previous)
        }
        edit.apply()
        lastEndReason = null
        publishLocked()
        return id
    }

    /**
     * Stores a renewed token pair, but only for [sessionId] and only while it is current:
     * a renewal that comes back after a sign-out, or after the next account signed in, is
     * dropped instead of bringing the old session back or overwriting the new one.
     */
    @Synchronized
    fun rotateIfCurrent(sessionId: String, accessToken: String, refreshToken: String): Boolean {
        require(accessToken.isNotBlank() && refreshToken.isNotBlank()) { "a renewal needs both tokens" }
        if (currentSessionIdLocked() != sessionId || prefs.getBoolean(KEY_DEMO_MODE, false)) return false
        prefs.edit()
            .putString(KEY_ACCESS_TOKEN, accessToken)
            .putString(KEY_REFRESH_TOKEN, refreshToken)
            .apply()
        publishLocked()
        return true
    }

    /**
     * THE end of a session. If [expectedSessionId] is current, ONE transaction removes every
     * credential (and everything else in this store, as sign-out always has) and writes the
     * teardown marker for that id; returns what was removed. Returns null, and changes
     * nothing, when that session is not current: already ended, or replaced by the next one.
     * Calling it twice is therefore harmless.
     */
    @Synchronized
    fun endIfCurrent(expectedSessionId: String, reason: EndReason): EndedSession? {
        val current = snapshotLocked() ?: return null
        if (current.sessionId != expectedSessionId) return null
        val ended = EndedSession(
            sessionId = expectedSessionId,
            accessToken = prefs.getString(KEY_ACCESS_TOKEN, null),
            refreshToken = prefs.getString(KEY_REFRESH_TOKEN, null),
            reason = reason,
        )
        // Editor.clear() is applied before the puts of the same transaction, so the marker
        // survives the wipe it belongs to.
        prefs.edit()
            .clear()
            .putString(KEY_TEARDOWN_PENDING, expectedSessionId)
            .apply()
        lastEndReason = reason
        publishLocked()
        return ended
    }

    /** [endIfCurrent] for whatever session is current, read and ended under one lock. */
    @Synchronized
    fun endCurrent(reason: EndReason): EndedSession? {
        val id = currentSessionIdLocked() ?: return null
        return endIfCurrent(id, reason)
    }

    /** Writes the profile fields that are not blank, only while [sessionId] is current. */
    @Synchronized
    fun setProfileIfCurrent(sessionId: String, userId: String?, name: String?, email: String?): Boolean {
        if (currentSessionIdLocked() != sessionId) return false
        val edit = prefs.edit()
        if (!userId.isNullOrBlank()) edit.putString(KEY_USER_ID, userId)
        if (!name.isNullOrBlank()) edit.putString(KEY_USER_NAME, name)
        if (!email.isNullOrBlank()) edit.putString(KEY_USER_EMAIL, email)
        edit.apply()
        return true
    }

    /** Records the device row registered for [sessionId], only while it is current. */
    @Synchronized
    fun setDeviceIdIfCurrent(sessionId: String, deviceId: String): Boolean {
        if (currentSessionIdLocked() != sessionId) return false
        prefs.edit().putString(KEY_DEVICE_ID, deviceId).apply()
        return true
    }

    /** Clears the teardown marker if it still names [sessionId] (a newer end replaces it). */
    @Synchronized
    fun clearPendingIfEquals(sessionId: String): Boolean {
        if (prefs.getString(KEY_TEARDOWN_PENDING, null) != sessionId) return false
        prefs.edit().remove(KEY_TEARDOWN_PENDING).apply()
        publishLocked()
        return true
    }

    // ── Pending OAuth flow (login or link) ─────────────────────────────
    // Durable across process death / backgrounding so we can complete the browser round-trip.

    /**
     * Pending-flow record. [kind] is "login" or "link". [state] is the CSRF token for the
     * authorize URL. [sessionId] is the session a link flow was started for (null for login).
     */
    data class PendingOAuthFlow(
        val kind: String,
        val provider: String,
        val codeVerifier: String,
        val state: String,
        val createdAt: Long,
        val sessionId: String? = null,
    )

    /** Max age of a pending flow before it's considered stale. */
    private val PENDING_TTL_MS = 10 * 60 * 1000L // 10 min

    @Synchronized
    fun savePendingOAuthFlow(flow: PendingOAuthFlow) {
        prefs.edit()
            .putString(KEY_PENDING_KIND, flow.kind)
            .putString(KEY_PENDING_PROVIDER, flow.provider)
            .putString(KEY_PENDING_VERIFIER, flow.codeVerifier)
            .putString(KEY_PENDING_STATE, flow.state)
            .putLong(KEY_PENDING_CREATED_AT, flow.createdAt)
            .putString(KEY_PENDING_SESSION_ID, flow.sessionId)
            .apply()
    }

    @Synchronized
    fun loadPendingOAuthFlow(): PendingOAuthFlow? {
        val kind = prefs.getString(KEY_PENDING_KIND, null) ?: return null
        val provider = prefs.getString(KEY_PENDING_PROVIDER, null) ?: return null
        val verifier = prefs.getString(KEY_PENDING_VERIFIER, null) ?: return null
        val state = prefs.getString(KEY_PENDING_STATE, null) ?: return null
        val createdAt = prefs.getLong(KEY_PENDING_CREATED_AT, 0L)
        if (createdAt == 0L || System.currentTimeMillis() - createdAt > PENDING_TTL_MS) {
            clearPendingOAuthFlow()
            return null
        }
        val sessionId = prefs.getString(KEY_PENDING_SESSION_ID, null)
        return PendingOAuthFlow(kind, provider, verifier, state, createdAt, sessionId)
    }

    /**
     * Removes the pending flow and returns it, once: a second delivery of the same callback
     * (a replayed intent, a double tap on the browser's return) gets null.
     */
    @Synchronized
    fun claimPendingOAuthFlow(): PendingOAuthFlow? {
        val flow = loadPendingOAuthFlow() ?: return null
        clearPendingOAuthFlow()
        return flow
    }

    @Synchronized
    fun clearPendingOAuthFlow() {
        val edit = prefs.edit()
        removePendingFlow(edit)
        edit.apply()
    }

    private fun removePendingFlow(edit: SharedPreferences.Editor) {
        edit.remove(KEY_PENDING_KIND)
            .remove(KEY_PENDING_PROVIDER)
            .remove(KEY_PENDING_VERIFIER)
            .remove(KEY_PENDING_STATE)
            .remove(KEY_PENDING_CREATED_AT)
            .remove(KEY_PENDING_SESSION_ID)
    }

    // Provider API keys
    fun saveProviderKey(provider: String, key: String) {
        prefs.edit().putString("provider_${provider}_apiKey", key).apply()
    }

    fun loadProviderKey(provider: String): String? =
        prefs.getString("provider_${provider}_apiKey", null)

    fun deleteProviderKey(provider: String) {
        prefs.edit().remove("provider_${provider}_apiKey").apply()
    }

    // ── Internals (call with the monitor held) ────────────────────────────

    /**
     * The current session's id. A session exists while there is a token or demo mode is on.
     * A session saved by 1.62 or earlier has no id yet: it gets one here, once.
     */
    private fun currentSessionIdLocked(): String? {
        val demo = prefs.getBoolean(KEY_DEMO_MODE, false)
        val hasToken = !prefs.getString(KEY_ACCESS_TOKEN, null).isNullOrBlank() ||
            !prefs.getString(KEY_REFRESH_TOKEN, null).isNullOrBlank()
        if (!demo && !hasToken) return null
        prefs.getString(KEY_SESSION_ID, null)?.takeIf { it.isNotBlank() }?.let { return it }
        val minted = (if (demo) DEMO_ID_PREFIX else "") + UUID.randomUUID().toString()
        prefs.edit().putString(KEY_SESSION_ID, minted).apply()
        return minted
    }

    private fun snapshotLocked(): SessionContext? {
        val id = currentSessionIdLocked() ?: return null
        val demo = prefs.getBoolean(KEY_DEMO_MODE, false)
        return SessionContext(
            sessionId = id,
            accessToken = if (demo) null else prefs.getString(KEY_ACCESS_TOKEN, null),
            refreshToken = if (demo) null else prefs.getString(KEY_REFRESH_TOKEN, null),
            userId = if (demo) null else prefs.getString(KEY_USER_ID, null),
            isDemo = demo,
        )
    }

    private fun readStateLocked(): SessionState {
        val id = currentSessionIdLocked()
        return SessionState(
            sessionId = id,
            isDemo = id != null && prefs.getBoolean(KEY_DEMO_MODE, false),
            endedReason = if (id == null) lastEndReason else null,
            teardownPending = prefs.getString(KEY_TEARDOWN_PENDING, null),
        )
    }

    private fun publishLocked() {
        _state.value = readStateLocked()
    }

    companion object {
        /** Prefix of demo mode's synthetic session id. */
        const val DEMO_ID_PREFIX = "demo-"

        private const val KEY_ACCESS_TOKEN = "access_token"
        private const val KEY_REFRESH_TOKEN = "refresh_token"
        private const val KEY_USER_ID = "user_id"
        private const val KEY_USER_NAME = "user_name"
        private const val KEY_USER_EMAIL = "user_email"
        private const val KEY_DEVICE_ID = "device_id"
        private const val KEY_DEMO_MODE = "demo_mode"
        private const val KEY_SESSION_ID = "session_id"
        private const val KEY_TEARDOWN_PENDING = "teardown_pending"
        private const val KEY_PENDING_KIND = "pending_oauth_kind"
        private const val KEY_PENDING_PROVIDER = "pending_oauth_provider"
        private const val KEY_PENDING_VERIFIER = "pending_oauth_verifier"
        private const val KEY_PENDING_STATE = "pending_oauth_state"
        private const val KEY_PENDING_CREATED_AT = "pending_oauth_created_at"
        private const val KEY_PENDING_SESSION_ID = "pending_oauth_session_id"
    }
}
