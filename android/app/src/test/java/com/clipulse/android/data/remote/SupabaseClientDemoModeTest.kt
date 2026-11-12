package com.clipulse.android.data.remote

import com.clipulse.android.data.DemoDataProvider
import com.clipulse.android.data.local.FakeCacheDao
import com.clipulse.android.data.session.SessionLifecycle
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.test.runTest
import okhttp3.OkHttpClient
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Before
import org.junit.Test

/**
 * The real SupabaseClient against a MockWebServer: demo mode answers from DemoDataProvider and
 * sends nothing; anything without a demo answer fails locally; a signed-out client sends
 * nothing; a signed-in client still sends its token.
 */
class SupabaseClientDemoModeTest {

    private lateinit var server: MockWebServer
    private lateinit var prefs: InMemorySharedPreferences
    private lateinit var tokenStore: TokenStore
    private lateinit var client: SupabaseClient

    @Before
    fun setUp() {
        server = MockWebServer()
        server.start()
        prefs = InMemorySharedPreferences()
        tokenStore = TokenStore(prefs)
        client = SupabaseClient(
            tokenStore,
            SessionLifecycle(
                tokenStore,
                FakeCacheDao(),
                CoroutineScope(SupervisorJob() + Dispatchers.Unconfined),
                Dispatchers.Unconfined,
            ),
            server.url("/").toString().trimEnd('/'),
            "anon-key-for-tests",
            OkHttpClient.Builder(),
        )
    }

    @After
    fun tearDown() {
        server.shutdown()
    }

    private fun enterDemo() {
        tokenStore.enterDemoMode()
    }

    @Test
    fun `demo mode reads answer from demo data and send nothing`() = runTest {
        enterDemo()

        assertEquals(DemoDataProvider.dashboard(), client.dashboard())
        assertEquals(DemoDataProvider.providers(), client.providers())
        // Demo timestamps are relative to now, so compare identities, not whole records.
        assertEquals(DemoDataProvider.devices().map { it.id }, client.devices().map { it.id })
        assertEquals(DemoDataProvider.sessions().map { it.id }, client.sessions().map { it.id })
        assertEquals(DemoDataProvider.alerts().map { it.id }, client.alerts().map { it.id })
        assertEquals(DemoDataProvider.dailyUsage(30).size, client.dailyUsage(30).size)
        assertTrue(client.dailyUsage(7).isNotEmpty())
        assertEquals("free", client.serverTier())
        assertEquals(0, client.evaluateBudgetAlerts())
        assertTrue(client.userIdentities().isEmpty())
        assertNotNull(client.settings())

        assertEquals(0, server.requestCount)
    }

    @Test
    fun `demo mode alert actions change the demo alerts and send nothing`() = runTest {
        enterDemo()
        val before = client.alerts().associateBy { it.id }
        assertFalse(before.getValue("a1").isRead)
        assertFalse(before.getValue("a2").isResolved)
        assertNull(before.getValue("a3").snoozedUntil)

        client.acknowledgeAlert("a1")
        client.resolveAlert("a2")
        client.snoozeAlert("a3", 60)

        val after = client.alerts().associateBy { it.id }
        assertTrue(after.getValue("a1").isRead)
        assertNotNull(after.getValue("a1").acknowledgedAt)
        assertTrue(after.getValue("a2").isResolved)
        assertNotNull(after.getValue("a3").snoozedUntil)
        assertEquals(before.getValue("a4"), after.getValue("a4"))
        assertEquals(0, server.requestCount)
    }

    @Test
    fun `demo mode fails a call with no demo answer before sending it (helper path)`() = runTest {
        enterDemo()
        try {
            client.rpcPublic("team_details")
            fail("an RPC should not succeed in demo mode")
        } catch (e: DemoModeRequestBlocked) {
            // expected
        }
        assertEquals(0, server.requestCount)
    }

    @Test
    fun `demo mode fails a raw request before sending it (interceptor path)`() = runTest {
        // health() builds its own request and swallows errors: the interceptor is the only guard.
        server.enqueue(MockResponse().setResponseCode(200).setBody("{}"))
        assertTrue("positive control: health reaches the server outside demo mode", client.health())
        assertEquals(1, server.requestCount)

        enterDemo()
        assertFalse(client.health())
        assertEquals(1, server.requestCount)
    }

    @Test
    fun `signed out with no tokens sends nothing and reports an expired session`() = runTest {
        try {
            client.sessions()
            fail("sessions() should not succeed signed out")
        } catch (e: ApiError.TokenExpired) {
            // expected
        }
        assertEquals(0, server.requestCount)
    }

    @Test
    fun `a refresh token alone renews first, then the request goes through`() = runTest {
        tokenStore.installSession(null, "refresh-1", "user-1")
        server.enqueue(MockResponse().setResponseCode(200).setBody("""{"access_token":"access-2","refresh_token":"refresh-2"}"""))
        server.enqueue(MockResponse().setResponseCode(200).setBody("[]"))

        assertTrue(client.sessions().isEmpty())
        assertEquals(2, server.requestCount)
        assertTrue(server.takeRequest().path!!.startsWith("/auth/v1/token?grant_type=refresh_token"))
        assertEquals("Bearer access-2", server.takeRequest().getHeader("Authorization"))
    }

    @Test
    fun `signed in requests still carry the access token`() = runTest {
        tokenStore.installSession("access-1", "refresh-1", "user-1")
        server.enqueue(MockResponse().setResponseCode(200).setBody("[]"))

        assertTrue(client.sessions().isEmpty())

        val request = server.takeRequest()
        assertEquals("Bearer access-1", request.getHeader("Authorization"))
        assertEquals("anon-key-for-tests", request.getHeader("apikey"))
        assertTrue(request.path!!.startsWith("/rest/v1/sessions?user_id=eq.user-1"))
    }

    @Test
    fun `a stale demo flag cannot outlive a real sign-in`() = runTest {
        enterDemo()
        tokenStore.installSession("access-1", "refresh-1", "user-1")
        assertFalse(tokenStore.isDemoMode)
        server.enqueue(MockResponse().setResponseCode(200).setBody("[]"))

        client.sessions()
        assertEquals(1, server.requestCount)
    }

    @Test
    fun `revoking an old session leaves the next account signed in`() = runTest {
        tokenStore.installSession("access-B", "refresh-B", "user-B")
        server.enqueue(MockResponse().setResponseCode(204))

        client.revokeSession(EndedSession("session-A", "access-A", "refresh-A", EndReason.UserSignedOut))

        val request = server.takeRequest()
        assertEquals("/auth/v1/logout?scope=local", request.path)
        assertEquals("Bearer access-A", request.getHeader("Authorization"))
        assertEquals(1, server.requestCount)
        assertEquals("access-B", tokenStore.snapshot()?.accessToken)
        assertEquals("refresh-B", tokenStore.snapshot()?.refreshToken)
    }

    @Test
    fun `a refresh that returns after sign-out does not bring the session back`() = runTest {
        val id = tokenStore.installSession("stale-1", "refresh-1", "user-1")!!
        server.dispatcher = object : okhttp3.mockwebserver.Dispatcher() {
            override fun dispatch(request: okhttp3.mockwebserver.RecordedRequest): MockResponse =
                if (request.path!!.startsWith("/auth/v1/token")) {
                    tokenStore.endIfCurrent(id, EndReason.UserSignedOut) // signed out while the refresh is out
                    MockResponse().setResponseCode(200)
                        .setBody("""{"access_token":"new-1","refresh_token":"new-r"}""")
                } else {
                    MockResponse().setResponseCode(401)
                }
        }

        try {
            client.sessions()
            fail("the refreshed session must not be used")
        } catch (e: ApiError.SessionSuperseded) {
            // expected: the session this request belonged to ended while it was out
        }
        assertNull(tokenStore.snapshot()?.accessToken)
        assertNull(tokenStore.snapshot()?.refreshToken)
    }
}
