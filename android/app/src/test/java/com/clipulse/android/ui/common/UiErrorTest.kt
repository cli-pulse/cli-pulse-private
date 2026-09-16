package com.clipulse.android.ui.common

import com.clipulse.android.data.remote.ApiError
import org.junit.Assert.assertEquals
import org.junit.Test
import java.io.IOException
import java.net.UnknownHostException

/**
 * Which sentence a failure gets. The words are string resources rendered in Compose
 * (JVM tests cannot resolve them); this pins the classification, which is where a
 * wrong password used to become "HTTP 400: {…GoTrue JSON…}" on the Login screen.
 */
class UiErrorTest {

    @Test
    fun `expired session`() {
        assertEquals(UiError.SessionExpired, UiError.from(ApiError.TokenExpired))
    }

    @Test
    fun `GoTrue invalid_credentials is a wrong email or password, not an HTTP code`() {
        val body = """{"code":400,"error_code":"invalid_credentials","msg":"Invalid login credentials"}"""
        assertEquals(UiError.InvalidCredentials, UiError.from(ApiError.Http(400, body)))
    }

    @Test
    fun `the older GoTrue error field is read too`() {
        val body = """{"error":"invalid_grant","error_description":"Invalid login credentials"}"""
        assertEquals(UiError.InvalidCredentials, UiError.from(ApiError.Http(400, body)))
    }

    @Test
    fun `an expired one-time code`() {
        val body = """{"code":403,"error_code":"otp_expired","msg":"Token has expired or is invalid"}"""
        assertEquals(UiError.CodeInvalidOrExpired, UiError.from(ApiError.Http(403, body)))
    }

    @Test
    fun `rate limits by code and by status`() {
        val body = """{"code":429,"error_code":"over_email_send_rate_limit","msg":"email rate limit exceeded"}"""
        assertEquals(UiError.RateLimited, UiError.from(ApiError.Http(429, body)))
        assertEquals(UiError.RateLimited, UiError.from(ApiError.Http(429, "")))
    }

    @Test
    fun `anything else is reported by status`() {
        assertEquals(UiError.Server(500), UiError.from(ApiError.Http(500, "<html>Bad Gateway</html>")))
        assertEquals(UiError.Server(400), UiError.from(ApiError.Http(400, """{"error_code":null}""")))
        assertEquals(UiError.Server(403), UiError.from(ApiError.Http(403, """{"error_code":"something_new"}""")))
    }

    @Test
    fun `network failures are offline`() {
        assertEquals(UiError.Offline, UiError.from(IOException("timeout")))
        assertEquals(UiError.Offline, UiError.from(UnknownHostException("clipulse.app")))
    }

    @Test
    fun `other exceptions keep their message for logs`() {
        assertEquals(UiError.Unknown("boom"), UiError.from(IllegalStateException("boom")))
    }

    @Test
    fun `a failed action wraps the cause`() {
        assertEquals(
            UiError.ActionFailed(UiError.Action.Resolve, UiError.Offline),
            UiError.action(UiError.Action.Resolve, IOException("reset")),
        )
    }
}
