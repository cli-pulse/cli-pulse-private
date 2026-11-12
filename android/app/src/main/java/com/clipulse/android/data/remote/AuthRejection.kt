package com.clipulse.android.data.remote

import org.json.JSONObject

/**
 * How a 401/403 answer to an authenticated request is treated. An explicit allowlist: only
 * shapes Supabase is documented to send end or renew a session; everything else is an
 * ordinary error that leaves the credentials alone.
 *
 * Verified against GoTrue `internal/api/auth.go` (`bad_jwt`, `session_not_found` and
 * `user_not_found` are all `NewForbiddenError`, i.e. 403; a missing bearer is 401
 * `no_authorization`) and the PostgREST error reference (`PGRST301` JWT cannot be decoded,
 * `PGRST303` claims validation failed, including expiry; `PGRST302` is "no bearer and the
 * anonymous role is disabled", not an expiry).
 */
internal enum class AuthRejection {
    /** Not an authentication rejection (403 `not_admin`, RLS `42501`, a proxy's 403, any other status). */
    None,

    /** The access token expired or cannot be verified: renew once, retry once. */
    Expiry,

    /** GoTrue says the session or the user is gone: end the session at once, no renewal. */
    SessionGone,

    /** A 401 that says nothing recognisable (HTML, a proxy's JSON, `PGRST302`): renew once; if it stays, keep the credentials. */
    Ambiguous,
}

internal fun classifyAuthRejection(path: String, code: Int, body: String?): AuthRejection {
    val json = body?.let(::parseJsonObject)
    return when (code) {
        403 -> {
            if (!path.startsWith("/auth/v1/") || json == null) return AuthRejection.None
            when (gotrueErrorCode(json)) {
                "session_not_found", "user_not_found" -> AuthRejection.SessionGone
                "bad_jwt" -> AuthRejection.Expiry
                else -> AuthRejection.None
            }
        }
        401 -> when (json?.stringOrNull("code")) {
            "PGRST301", "PGRST303" -> AuthRejection.Expiry
            else -> AuthRejection.Ambiguous
        }
        else -> AuthRejection.None
    }
}

/** The answer to one `grant_type=refresh_token` request. */
internal sealed class RefreshOutcome {
    /** 200 with BOTH a non-blank access token and a non-blank refresh token. */
    data class Renewed(val accessToken: String, val refreshToken: String) : RefreshOutcome() {
        override fun toString(): String = "Renewed"
    }

    /** GoTrue definitively refused the refresh token: the session cannot be renewed, ever. */
    data class Refused(val status: Int, val errorCode: String) : RefreshOutcome()

    /** Anything else (offline, 408, 429, 5xx, an unknown or a proxy's answer, a 200 without both tokens). */
    data class Failed(val error: Exception) : RefreshOutcome()
}

/**
 * `error_code` values (400/401/403) that mean the refresh token will never work again. Any
 * other code, including `bad_json` and `over_request_rate_limit`, is not a refusal.
 */
internal val REFRESH_REFUSED_CODES = setOf(
    "refresh_token_not_found",
    "refresh_token_already_used",
    "session_not_found",
    "session_expired",
    "user_not_found",
)

internal fun classifyRefreshResponse(code: Int, body: String): RefreshOutcome {
    val json = parseJsonObject(body)
    if (code in 200..299) {
        val access = json?.stringOrNull("access_token")
        val refresh = json?.stringOrNull("refresh_token")
        // Never put this body into an error: it may hold a token.
        return if (access != null && refresh != null) {
            RefreshOutcome.Renewed(access, refresh)
        } else {
            RefreshOutcome.Failed(ApiError.Http(code, "refresh answer without both tokens"))
        }
    }
    if (code == 400 || code == 401 || code == 403) {
        val errorCode = json?.let(::gotrueErrorCode)
        if (errorCode != null) {
            if (errorCode in REFRESH_REFUSED_CODES) return RefreshOutcome.Refused(code, errorCode)
        } else if (json?.stringOrNull("error") == "invalid_grant") {
            // The older GoTrue shape: {"error":"invalid_grant","error_description":"Invalid Refresh Token: …"}.
            return RefreshOutcome.Refused(code, "invalid_grant")
        }
    }
    return RefreshOutcome.Failed(ApiError.Http(code, body))
}

/**
 * GoTrue's error code: `error_code` in current versions, a non-numeric string `code` in
 * others (a numeric `code` is the HTTP status, a `PGRST…` one is PostgREST's).
 */
internal fun gotrueErrorCode(json: JSONObject): String? =
    json.stringOrNull("error_code")
        ?: json.stringOrNull("code")?.takeIf { c -> !c.startsWith("PGRST") && c.any { !it.isDigit() } }

/**
 * True when the access token [token] has expired, with a small margin. With
 * [receivedAtMillis] (when this device received the token, by its own clock) and an `iat`
 * claim, the lifetime `exp - iat` is counted from the receipt, so a phone clock that runs
 * ahead does not make every fresh token look expired (and renew on every request). Without
 * them, `exp` is compared with [nowMillis]. A token that is not a JWT, or has no readable
 * `exp`, counts as not expired: the server decides.
 */
internal fun isAccessTokenExpired(token: String, nowMillis: Long, receivedAtMillis: Long? = null): Boolean {
    val parts = token.split('.')
    if (parts.size != 3) return false
    val payload = try {
        String(java.util.Base64.getUrlDecoder().decode(parts[1]), Charsets.UTF_8)
    } catch (e: IllegalArgumentException) {
        return false
    }
    val json = parseJsonObject(payload) ?: return false
    if (!json.has("exp") || json.isNull("exp")) return false
    val exp = json.optLong("exp", 0L)
    if (exp <= 0L) return false
    val iat = if (json.has("iat") && !json.isNull("iat")) json.optLong("iat", 0L) else 0L
    val expiresAt = if (receivedAtMillis != null && iat in 1 until exp) {
        receivedAtMillis + (exp - iat) * 1000L
    } else {
        exp * 1000L
    }
    return expiresAt <= nowMillis + EXPIRY_MARGIN_MS
}

/** Renew a little before the exact second, so a request does not leave with a token that dies on the way. */
private const val EXPIRY_MARGIN_MS = 30_000L

internal fun parseJsonObject(text: String): JSONObject? {
    val trimmed = text.trim()
    if (!trimmed.startsWith("{")) return null
    return try {
        JSONObject(trimmed)
    } catch (e: Exception) {
        null
    }
}

/**
 * A non-blank string value, or null. `has`/`isNull` first: on a device org.json returns the
 * string "null" for a JSON null, while the JVM library used by unit tests returns the fallback.
 */
internal fun JSONObject.stringOrNull(key: String): String? {
    if (!has(key) || isNull(key)) return null
    return optString(key).takeIf { it.isNotBlank() }
}
