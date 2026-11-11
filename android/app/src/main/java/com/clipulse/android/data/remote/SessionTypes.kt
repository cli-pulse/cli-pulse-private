package com.clipulse.android.data.remote

/**
 * Why a session ended. Every way a session can end goes through [TokenStore.endIfCurrent]
 * with one of these, so "signed out", "refused by the server" and "account deleted" are one
 * transition, not five copies of a credential wipe.
 */
enum class EndReason {
    /** The server definitively refused the session (a refused renewal, a second rejection). */
    SessionRefused,
    /** GoTrue said the session or the user no longer exists (`session_not_found`, `user_not_found`). */
    SessionGone,
    UserSignedOut,
    AccountDeleted,
    DemoExit,
}

/**
 * One session, read in ONE synchronized step ([TokenStore.snapshot]). Every request of an
 * operation carries it, so a sign-out or the next account's sign-in between two requests can
 * never make the second one run as somebody else: the client refuses to send for a session
 * that is no longer current.
 *
 * [sessionId] is a random id written together with the credentials at sign-in. A token
 * renewal keeps it; a new sign-in, a sign-out or demo mode changes it. Demo mode has its own
 * synthetic id (`demo-<uuid>`) and no tokens.
 */
data class SessionContext(
    val sessionId: String,
    val accessToken: String?,
    val refreshToken: String?,
    val userId: String?,
    val isDemo: Boolean,
    /** When this device received [accessToken] (its own clock); null for a 1.62 session. */
    val accessReceivedAt: Long? = null,
) {
    // Tokens never go into logs or crash reports through a data class's generated toString.
    override fun toString(): String = "SessionContext(isDemo=$isDemo)"
}

/**
 * What [TokenStore.endIfCurrent] removed, captured in the same synchronized commit that
 * removed it, so a server-side revocation can use exactly the credentials that ended and
 * never a rotated or a later account's pair.
 */
data class EndedSession(
    val sessionId: String,
    val accessToken: String?,
    val refreshToken: String?,
    val reason: EndReason,
) {
    override fun toString(): String = "EndedSession(reason=$reason)"
}

/**
 * The session as the rest of the app sees it, published by [TokenStore.state] after every
 * change. A StateFlow replays the current value to a late collector, so nothing depends on
 * a collector existing at the moment a session ends.
 *
 * [teardownPending] is the id of an ended session whose on-device data (Room cache and the
 * repository's in-memory rows) has not been deleted yet. It is durable: it is written in the
 * same commit as the credential wipe, so a process death between the two is finished at the
 * next start.
 */
data class SessionState(
    val sessionId: String?,
    val isDemo: Boolean,
    val endedReason: EndReason?,
    val teardownPending: String?,
)
