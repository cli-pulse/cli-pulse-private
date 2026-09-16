package com.clipulse.android.ui.common

import com.clipulse.android.data.remote.ApiError
import org.json.JSONObject
import java.io.IOException

/**
 * An error a screen shows, as a KIND rather than a sentence.
 *
 * View models used to put `e.message` or an English sentence into UI state, so the
 * Login screen read `HTTP 400: {"code":400,"error_code":"invalid_credentials",…}` for a
 * wrong password and Overview said "Session expired. Please sign in again." in every
 * language. The words now come from string resources in the Composable
 * ([text]); the exception's own message stays in [Unknown.detail] and in logs.
 */
sealed class UiError {
    data object SessionExpired : UiError()
    data object Offline : UiError()
    /** Session refresh failed transiently; the app carries on with the tokens it has. */
    data object OfflineUsingCachedSession : UiError()
    data object InvalidCredentials : UiError()
    data object CodeInvalidOrExpired : UiError()
    data object RateLimited : UiError()
    data class Server(val httpCode: Int) : UiError()
    data class Unknown(val detail: String?) : UiError()
    data class ActionFailed(val action: Action, val cause: UiError) : UiError()

    enum class Action { Acknowledge, Resolve, Snooze, DeleteAccount, LoadLinkedAccounts, StartLink, Link, Unlink }

    companion object {
        // GoTrue `error_code` values (and the older `error` field) that have a
        // sentence of their own. Anything else is reported by HTTP status.
        private val INVALID_CREDENTIALS = setOf("invalid_credentials", "invalid_grant", "user_not_found")
        private val CODE_INVALID = setOf("otp_expired", "otp_disabled", "bad_code_verifier", "flow_state_expired")
        private val RATE_LIMITED = setOf(
            "over_email_send_rate_limit", "over_request_rate_limit", "over_sms_send_rate_limit",
        )

        fun from(error: Throwable): UiError = when (error) {
            is ApiError.TokenExpired -> SessionExpired
            is ApiError.Http -> fromHttp(error.code, error.body)
            is IOException -> Offline
            else -> Unknown(error.message)
        }

        fun action(action: Action, error: Throwable): UiError = ActionFailed(action, from(error))

        internal fun fromHttp(code: Int, body: String): UiError {
            val errorCode = errorCode(body)
            return when {
                errorCode in INVALID_CREDENTIALS -> InvalidCredentials
                errorCode in CODE_INVALID -> CodeInvalidOrExpired
                errorCode in RATE_LIMITED || code == 429 -> RateLimited
                else -> Server(code)
            }
        }

        /** `error_code`, else `error`, from a GoTrue JSON body; null when the body is not JSON. */
        private fun errorCode(body: String): String? = try {
            val json = JSONObject(body)
            // isNull before optString: Android's org.json returns the string "null" for a
            // JSON null, while the JVM library used by unit tests returns the fallback.
            listOf("error_code", "error").firstNotNullOfOrNull { key ->
                if (json.has(key) && !json.isNull(key)) json.optString(key).takeIf { it.isNotBlank() } else null
            }
        } catch (_: Exception) {
            null
        }
    }
}
