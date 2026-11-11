package com.clipulse.android.data.remote

import android.content.Context
import android.content.SharedPreferences
import androidx.security.crypto.EncryptedSharedPreferences
import androidx.security.crypto.MasterKey
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import java.util.UUID

/**
 * The encrypted credential store. Every mutator runs under this object's monitor and writes
 * in a single `SharedPreferences.Editor` transaction, then publishes [state]. A session is
 * identified by a random `sessionId` written with its credentials; every write that belongs
 * to a session is conditional on that session still being the current one.
 *
 * Session transitions ([installSession], [enterDemoMode], [endIfCurrent], [clearPendingIfEquals])
 * are called ONLY by SessionLifecycle, which serialises them with cache writes, hydration and
 * the deletion of an ended session's data (SessionNavigationWiringTest checks the sources).
 * They and token rotations use `commit()`: they run on an IO thread, and the next account's
 * cache writes must never be durable while the transition that allowed them is not. Any
 * successful commit writes the whole map, so one success also makes every earlier change
 * durable; [isDurable] reports whether the last commit reached disk.
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

    /** False after a commit that did not reach disk, until one does. */
    private var durable = true

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

    /** Whether the last commit reached disk (see the class comment). */
    val isDurable: Boolean
        @Synchronized get() = durable

    /** The current sign-in generation (see [beginAuthAttempt]). */
    val authGeneration: Long
        @Synchronized get() = prefs.getLong(KEY_AUTH_GENERATION, 0L)

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

    // ── Sign-in generations ───────────────────────────────────────────────

    /**
     * Starts a sign-in attempt: the generation moves on and is returned. Only an attempt
     * whose generation is still the current one may install its session ([installSession]),
     * so a newer attempt, demo mode or an explicit [abandonAuthAttempts] overtakes every
     * older one, whichever order the answers come back in.
     */
    @Synchronized
    fun beginAuthAttempt(): Long = nextGenerationLocked(prefs.edit()).also { it.second.apply() }.first

    /**
     * Starts a browser sign-in: the generation moves on and is saved WITH the pending flow
     * in one transaction, so the callback carries the generation of the moment the user
     * left for the browser (across a process death too), not of the moment it came back.
     */
    @Synchronized
    fun beginOAuthLogin(flow: PendingOAuthFlow): Long {
        val (generation, edit) = nextGenerationLocked(prefs.edit())
        putPendingFlow(edit, flow.copy(authGeneration = generation))
        edit.apply()
        return generation
    }

    /** Every sign-in attempt started so far may no longer install a session. */
    @Synchronized
    fun abandonAuthAttempts() {
        nextGenerationLocked(prefs.edit()).second.apply()
    }

    private fun nextGenerationLocked(edit: SharedPreferences.Editor): Pair<Long, SharedPreferences.Editor> {
        val next = prefs.getLong(KEY_AUTH_GENERATION, 0L) + 1
        return next to edit.putLong(KEY_AUTH_GENERATION, next)
    }

    // ── Session transitions (SessionLifecycle only) ───────────────────────

    /**
     * Installs a signed-in session with a fresh id, in one committed transaction, if
     * [attempt] is still the current sign-in generation (null: no attempt check). Null
     * means it was overtaken and nothing was written.
     *
     * Ends demo mode, forgets the previous session's device row and every pending OAuth
     * flow (an abandoned browser sign-in must not complete over this session later). If a
     * session was current, its id becomes the teardown marker.
     */
    @Synchronized
    fun installSession(
        accessToken: String?,
        refreshToken: String?,
        userId: String?,
        userName: String? = null,
        userEmail: String? = null,
        attempt: Long? = null,
        receivedAtMillis: Long = System.currentTimeMillis(),
    ): String? {
        require(!accessToken.isNullOrBlank() || !refreshToken.isNullOrBlank()) { "a session needs a token" }
        if (attempt != null && attempt != prefs.getLong(KEY_AUTH_GENERATION, 0L)) return null
        val previous = currentSessionIdLocked()
        val id = UUID.randomUUID().toString()
        val edit = prefs.edit()
            .putString(KEY_ACCESS_TOKEN, accessToken)
            .putString(KEY_REFRESH_TOKEN, refreshToken)
            .putLong(KEY_ACCESS_RECEIVED_AT, receivedAtMillis)
            .putString(KEY_USER_ID, userId)
            .putString(KEY_USER_NAME, userName)
            .putString(KEY_USER_EMAIL, userEmail)
            .putString(KEY_SESSION_ID, id)
            .putBoolean(KEY_DEMO_MODE, false)
            .remove(KEY_DEVICE_ID)
        removePendingFlow(edit)
        if (previous != null) edit.putString(KEY_TEARDOWN_PENDING, previous)
        commitLocked(edit)
        lastEndReason = null
        publishLocked()
        return id
    }

    /**
     * Demo mode as a session of its own: the flag and a synthetic `demo-<uuid>` id in one
     * committed transaction, so leaving it is the same [endIfCurrent] as any other end. It
     * also abandons every sign-in still out and drops pending OAuth flows: a password
     * answer or a browser callback that arrives later must not replace the demo.
     */
    @Synchronized
    fun enterDemoMode(): String {
        val previous = currentSessionIdLocked()
        if (previous != null && prefs.getBoolean(KEY_DEMO_MODE, false)) return previous
        val id = DEMO_ID_PREFIX + UUID.randomUUID().toString()
        val edit = nextGenerationLocked(prefs.edit()).second
            .putBoolean(KEY_DEMO_MODE, true)
            .putString(KEY_SESSION_ID, id)
        removePendingFlow(edit)
        if (previous != null) {
            edit.remove(KEY_ACCESS_TOKEN).remove(KEY_REFRESH_TOKEN).remove(KEY_ACCESS_RECEIVED_AT)
                .remove(KEY_USER_ID).remove(KEY_USER_NAME).remove(KEY_USER_EMAIL).remove(KEY_DEVICE_ID)
                .putString(KEY_TEARDOWN_PENDING, previous)
        }
        commitLocked(edit)
        lastEndReason = null
        publishLocked()
        return id
    }

    /**
     * Stores a renewed token pair, but only for [sessionId] and only while it is current:
     * a renewal that comes back after a sign-out, or after the next account signed in, is
     * dropped instead of bringing the old session back or overwriting the new one. The
     * client serialises every token-producing request with its refresh mutex.
     */
    @Synchronized
    fun rotateIfCurrent(
        sessionId: String,
        accessToken: String,
        refreshToken: String,
        receivedAtMillis: Long = System.currentTimeMillis(),
    ): Boolean {
        require(accessToken.isNotBlank() && refreshToken.isNotBlank()) { "a renewal needs both tokens" }
        if (currentSessionIdLocked() != sessionId || prefs.getBoolean(KEY_DEMO_MODE, false)) return false
        commitLocked(
            prefs.edit()
                .putString(KEY_ACCESS_TOKEN, accessToken)
                .putString(KEY_REFRESH_TOKEN, refreshToken)
                .putLong(KEY_ACCESS_RECEIVED_AT, receivedAtMillis),
        )
        publishLocked()
        return true
    }

    /**
     * THE end of a session. If [expectedSessionId] is current, ONE committed transaction
     * removes every credential (and everything else in this store, as sign-out always has,
     * except the sign-in generation and the one-time cache check) and writes the teardown
     * marker for that id; returns what was removed. Returns null, and changes nothing, when
     * that session is not current: already ended, or replaced by the next one.
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
        val generation = prefs.getLong(KEY_AUTH_GENERATION, 0L)
        val cacheChecked = prefs.getBoolean(KEY_LEGACY_CACHE_CHECKED, false)
        // Editor.clear() is applied before the puts of the same transaction, so the marker
        // survives the wipe it belongs to.
        commitLocked(
            prefs.edit()
                .clear()
                .putString(KEY_TEARDOWN_PENDING, expectedSessionId)
                .putLong(KEY_AUTH_GENERATION, generation)
                .putBoolean(KEY_LEGACY_CACHE_CHECKED, cacheChecked),
        )
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

    /** Clears the teardown marker if it still names [sessionId]; true only if that reached disk. */
    @Synchronized
    fun clearPendingIfEquals(sessionId: String): Boolean {
        if (prefs.getString(KEY_TEARDOWN_PENDING, null) != sessionId) return false
        commitLocked(prefs.edit().remove(KEY_TEARDOWN_PENDING))
        publishLocked()
        return durable
    }

    /**
     * First start of a version with session teardown: if no session is stored, an older
     * version may have signed out without deleting its cache. Marks it for teardown, once.
     */
    @Synchronized
    fun markLegacyCacheForTeardownIfNeeded(): Boolean {
        if (prefs.getBoolean(KEY_LEGACY_CACHE_CHECKED, false)) return false
        val edit = prefs.edit().putBoolean(KEY_LEGACY_CACHE_CHECKED, true)
        val mark = currentSessionIdLocked() == null && prefs.getString(KEY_TEARDOWN_PENDING, null) == null
        if (mark) edit.putString(KEY_TEARDOWN_PENDING, LEGACY_CACHE_MARKER)
        commitLocked(edit)
        publishLocked()
        return mark
    }

    /** Writes the whole map again; true when it reached disk. */
    @Synchronized
    fun recommit(): Boolean {
        commitLocked(prefs.edit().putLong(KEY_DURABILITY_PROBE, System.nanoTime()))
        return durable
    }

    // ── Session-bound writes ──────────────────────────────────────────────

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

    // ── Pending OAuth flow (login or link) ─────────────────────────────
    // Durable across process death / backgrounding so we can complete the browser round-trip.

    /**
     * Pending-flow record. [kind] is "login" or "link". [state] is the CSRF token for the
     * authorize URL. [sessionId] is the session a link flow belongs to; [authGeneration] is
     * the sign-in generation a login flow was started with ([beginOAuthLogin]).
     */
    data class PendingOAuthFlow(
        val kind: String,
        val provider: String,
        val codeVerifier: String,
        val state: String,
        val createdAt: Long,
        val sessionId: String? = null,
        val authGeneration: Long? = null,
    )

    /** Max age of a pending flow before it's considered stale. */
    private val PENDING_TTL_MS = 10 * 60 * 1000L // 10 min

    /** Saves a link flow (login flows go through [beginOAuthLogin]). */
    @Synchronized
    fun savePendingOAuthFlow(flow: PendingOAuthFlow) {
        val edit = prefs.edit()
        putPendingFlow(edit, flow)
        edit.apply()
    }

    private fun putPendingFlow(edit: SharedPreferences.Editor, flow: PendingOAuthFlow) {
        edit.putString(KEY_PENDING_KIND, flow.kind)
            .putString(KEY_PENDING_PROVIDER, flow.provider)
            .putString(KEY_PENDING_VERIFIER, flow.codeVerifier)
            .putString(KEY_PENDING_STATE, flow.state)
            .putLong(KEY_PENDING_CREATED_AT, flow.createdAt)
            .putString(KEY_PENDING_SESSION_ID, flow.sessionId)
        if (flow.authGeneration != null) {
            edit.putLong(KEY_PENDING_GENERATION, flow.authGeneration)
        } else {
            edit.remove(KEY_PENDING_GENERATION)
        }
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
        val generation = if (prefs.contains(KEY_PENDING_GENERATION)) prefs.getLong(KEY_PENDING_GENERATION, 0L) else null
        return PendingOAuthFlow(kind, provider, verifier, state, createdAt, sessionId, generation)
    }

    /**
     * Removes the pending flow and returns it, once: a second delivery of the same callback
     * (a replayed intent, a double tap on the browser's return) gets null.
     *
     * A link flow saved by 1.62 has no session id. Every sign-in and sign-out since it was
     * saved would have dropped it, so it belongs to the session current NOW: it is bound to
     * that session here, under the same lock, and the exchange later requires exactly that
     * session. With no session, it is discarded.
     */
    @Synchronized
    fun claimPendingOAuthFlow(): PendingOAuthFlow? {
        val flow = loadPendingOAuthFlow() ?: return null
        clearPendingOAuthFlow()
        if (flow.kind == "link" && flow.sessionId == null) {
            val owner = currentSessionIdLocked() ?: return null
            return flow.copy(sessionId = owner)
        }
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
            .remove(KEY_PENDING_GENERATION)
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

    private fun commitLocked(edit: SharedPreferences.Editor) {
        durable = edit.commit()
    }

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
        // apply(), not commit(): this can run on the main thread at start-up, and a lost id is
        // simply minted again (nothing outside this process remembers it).
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
            accessReceivedAt = if (demo || !prefs.contains(KEY_ACCESS_RECEIVED_AT)) {
                null
            } else {
                prefs.getLong(KEY_ACCESS_RECEIVED_AT, 0L)
            },
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

        /** Teardown marker for cache rows an older version may have left behind. */
        const val LEGACY_CACHE_MARKER = "legacy-cache"

        private const val KEY_ACCESS_TOKEN = "access_token"
        private const val KEY_REFRESH_TOKEN = "refresh_token"
        private const val KEY_ACCESS_RECEIVED_AT = "access_received_at"
        private const val KEY_USER_ID = "user_id"
        private const val KEY_USER_NAME = "user_name"
        private const val KEY_USER_EMAIL = "user_email"
        private const val KEY_DEVICE_ID = "device_id"
        private const val KEY_DEMO_MODE = "demo_mode"
        private const val KEY_SESSION_ID = "session_id"
        private const val KEY_TEARDOWN_PENDING = "teardown_pending"
        private const val KEY_AUTH_GENERATION = "auth_generation"
        private const val KEY_LEGACY_CACHE_CHECKED = "legacy_cache_checked"
        private const val KEY_DURABILITY_PROBE = "durability_probe"
        private const val KEY_PENDING_KIND = "pending_oauth_kind"
        private const val KEY_PENDING_PROVIDER = "pending_oauth_provider"
        private const val KEY_PENDING_VERIFIER = "pending_oauth_verifier"
        private const val KEY_PENDING_STATE = "pending_oauth_state"
        private const val KEY_PENDING_CREATED_AT = "pending_oauth_created_at"
        private const val KEY_PENDING_SESSION_ID = "pending_oauth_session_id"
        private const val KEY_PENDING_GENERATION = "pending_oauth_generation"
    }
}
