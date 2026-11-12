package com.clipulse.android.data.remote

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** The allowlists themselves, row by row. The client tests drive the same rows end to end. */
class AuthRejectionTest {

    private fun gotrue(code: String) = """{"code":403,"error_code":"$code","msg":"x"}"""

    @Test
    fun `GoTrue 403s with a recognised error code`() {
        assertEquals(AuthRejection.Expiry, classifyAuthRejection("/auth/v1/user", 403, gotrue("bad_jwt")))
        assertEquals(AuthRejection.SessionGone, classifyAuthRejection("/auth/v1/user", 403, gotrue("session_not_found")))
        assertEquals(AuthRejection.SessionGone, classifyAuthRejection("/auth/v1/user", 403, gotrue("user_not_found")))
    }

    @Test
    fun `GoTrue's other error shape, a string code, is read the same way`() {
        assertEquals(AuthRejection.SessionGone, classifyAuthRejection("/auth/v1/user", 403, """{"code":"session_not_found","message":"x"}"""))
        assertEquals(AuthRejection.Expiry, classifyAuthRejection("/auth/v1/user", 403, """{"code":"bad_jwt","message":"x"}"""))
        assertEquals(
            RefreshOutcome.Refused(400, "refresh_token_not_found"),
            classifyRefreshResponse(400, """{"code":"refresh_token_not_found","message":"x"}"""),
        )
        assertTrue(
            "a numeric code is the HTTP status, not an error code",
            classifyRefreshResponse(400, """{"code":400,"msg":"x"}""") is RefreshOutcome.Failed,
        )
    }

    @Test
    fun `an ordinary 403 is not a rejection of the session`() {
        assertEquals(AuthRejection.None, classifyAuthRejection("/auth/v1/user", 403, gotrue("not_admin")))
        assertEquals(AuthRejection.None, classifyAuthRejection("/auth/v1/user", 403, "<html>Forbidden</html>"))
        assertEquals(AuthRejection.None, classifyAuthRejection("/auth/v1/user", 403, ""))
        assertEquals(
            "RLS",
            AuthRejection.None,
            classifyAuthRejection("/rest/v1/alerts", 403, """{"code":"42501","message":"permission denied"}"""),
        )
        assertEquals(
            "session_not_found only counts on a GoTrue path",
            AuthRejection.None,
            classifyAuthRejection("/rest/v1/alerts", 403, gotrue("session_not_found")),
        )
        assertEquals(
            "a proxy's JSON",
            AuthRejection.None,
            classifyAuthRejection("/auth/v1/user", 403, """{"message":"upstream"}"""),
        )
    }

    @Test
    fun `bad_jwt counts only as a 403`() {
        assertEquals(AuthRejection.Ambiguous, classifyAuthRejection("/auth/v1/user", 401, gotrue("bad_jwt")))
        assertEquals(AuthRejection.None, classifyAuthRejection("/auth/v1/user", 400, gotrue("bad_jwt")))
    }

    @Test
    fun `PostgREST JWT errors`() {
        assertEquals(AuthRejection.Expiry, classifyAuthRejection("/rest/v1/x", 401, """{"code":"PGRST301","message":"JWSError"}"""))
        assertEquals(AuthRejection.Expiry, classifyAuthRejection("/rest/v1/x", 401, """{"code":"PGRST303","message":"JWT expired"}"""))
        assertEquals(
            "PGRST302 is not an expiry",
            AuthRejection.Ambiguous,
            classifyAuthRejection("/rest/v1/x", 401, """{"code":"PGRST302","message":"Anonymous access is disabled"}"""),
        )
    }

    @Test
    fun `any other 401 is ambiguous`() {
        assertEquals(AuthRejection.Ambiguous, classifyAuthRejection("/rest/v1/x", 401, "<html>Unauthorized</html>"))
        assertEquals(AuthRejection.Ambiguous, classifyAuthRejection("/functions/v1/x", 401, """{"code":401,"message":"Invalid JWT"}"""))
        assertEquals(AuthRejection.Ambiguous, classifyAuthRejection("/rest/v1/x", 401, ""))
    }

    @Test
    fun `other statuses are never rejections`() {
        for (code in listOf(400, 404, 408, 429, 500, 502, 503)) {
            assertEquals("HTTP $code", AuthRejection.None, classifyAuthRejection("/auth/v1/user", code, gotrue("bad_jwt")))
        }
    }

    @Test
    fun `refresh refusals are an explicit allowlist`() {
        for (code in REFRESH_REFUSED_CODES) {
            val outcome = classifyRefreshResponse(400, """{"code":400,"error_code":"$code","msg":"x"}""")
            assertEquals(code, RefreshOutcome.Refused(400, code), outcome)
        }
        assertEquals(
            RefreshOutcome.Refused(400, "invalid_grant"),
            classifyRefreshResponse(400, """{"error":"invalid_grant","error_description":"Invalid Refresh Token"}"""),
        )
    }

    @Test
    fun `everything else from the refresh endpoint is a failure, not a refusal`() {
        val notRefusals = listOf(
            400 to """{"code":400,"error_code":"bad_json","msg":"x"}""",
            429 to """{"code":429,"error_code":"over_request_rate_limit","msg":"x"}""",
            400 to """{"code":400,"error_code":"something_new","msg":"x"}""",
            403 to """{"message":"upstream"}""",
            400 to "<html>Bad Request</html>",
            408 to "",
            500 to """{"code":500,"msg":"x"}""",
            503 to "",
            502 to "<html>Bad Gateway</html>",
            401 to """{"error":"unauthorized"}""",
        )
        for ((code, body) in notRefusals) {
            val outcome = classifyRefreshResponse(code, body)
            assertTrue("$code $body -> $outcome", outcome is RefreshOutcome.Failed)
        }
    }

    @Test
    fun `a 200 renews only with both tokens`() {
        assertEquals(
            RefreshOutcome.Renewed("new-access", "new-refresh"),
            classifyRefreshResponse(200, """{"access_token":"new-access","refresh_token":"new-refresh"}"""),
        )
        assertTrue(classifyRefreshResponse(200, "{}") is RefreshOutcome.Failed)
        assertTrue(classifyRefreshResponse(200, """{"access_token":"new-access"}""") is RefreshOutcome.Failed)
        assertTrue(classifyRefreshResponse(200, """{"access_token":"new-access","refresh_token":""}""") is RefreshOutcome.Failed)
        assertTrue(classifyRefreshResponse(200, """{"refresh_token":"new-refresh"}""") is RefreshOutcome.Failed)
        val failed = classifyRefreshResponse(200, """{"access_token":"new-access"}""") as RefreshOutcome.Failed
        assertFalse("the token never goes into the error", failed.error.message!!.contains("new-access"))
    }

    @Test
    fun `a phone clock running ahead does not make a token it just received look expired`() {
        val serverNow = 1_800_000_000L
        val token = TestJwt.of("""{"sub":"user-a","iat":$serverNow,"exp":${serverNow + 3600}}""")
        val phoneNow = (serverNow + 7200) * 1000L // two hours ahead
        assertTrue("by exp alone it looks expired", isAccessTokenExpired(token, phoneNow))
        assertFalse(
            "counted from when it arrived, it has an hour left",
            isAccessTokenExpired(token, phoneNow, receivedAtMillis = phoneNow - 60_000L),
        )
        assertTrue(
            "and it does expire an hour after it arrived",
            isAccessTokenExpired(token, phoneNow + 3600_000L, receivedAtMillis = phoneNow),
        )
    }

    @Test
    fun `access token expiry is read from the JWT`() {
        val now = 1_800_000_000_000L
        assertTrue(isAccessTokenExpired(TestJwt.withExp(now / 1000 - 60), now))
        assertTrue("inside the margin", isAccessTokenExpired(TestJwt.withExp(now / 1000 + 5), now))
        assertFalse(isAccessTokenExpired(TestJwt.withExp(now / 1000 + 3600), now))
        assertFalse("not a JWT", isAccessTokenExpired("access-A", now))
        assertFalse("no exp", isAccessTokenExpired(TestJwt.of("""{"sub":"user-a"}"""), now))
        assertFalse("garbage payload", isAccessTokenExpired("a.%%%.c", now))
    }
}

/** Unsigned, invented JWTs built at run time; nothing here is a real credential. */
internal object TestJwt {
    private val encoder = java.util.Base64.getUrlEncoder().withoutPadding()

    fun of(payloadJson: String): String {
        val header = encoder.encodeToString("""{"alg":"none","typ":"JWT"}""".toByteArray())
        val payload = encoder.encodeToString(payloadJson.toByteArray())
        return "$header.$payload.test-signature"
    }

    fun withExp(expEpochSeconds: Long, subject: String = "user-a"): String =
        of("""{"sub":"$subject","exp":$expEpochSeconds}""")

    fun expired(subject: String = "user-a"): String = withExp(System.currentTimeMillis() / 1000 - 3600, subject)

    fun fresh(subject: String = "user-a"): String = withExp(System.currentTimeMillis() / 1000 + 3600, subject)
}
