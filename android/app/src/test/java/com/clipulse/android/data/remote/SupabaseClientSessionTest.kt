package com.clipulse.android.data.remote

import com.clipulse.android.data.local.FakeCacheDao
import com.clipulse.android.data.session.SessionLifecycle
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import okhttp3.OkHttpClient
import okhttp3.mockwebserver.Dispatcher
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import okhttp3.mockwebserver.RecordedRequest
import okhttp3.mockwebserver.SocketPolicy
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Before
import org.junit.Test
import java.io.IOException
import java.util.Collections
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicReference

/**
 * The real SupabaseClient against a MockWebServer and a real TokenStore: which answers renew,
 * end or leave a session alone, and that every request of an operation runs for the session
 * it started with. Barriers are latches inside the server's dispatcher (or the client's
 * after-request hook), never sleeps. OkHttp's own connection retry is off, so a request count
 * is a count of wire attempts.
 */
class SupabaseClientSessionTest {

    private lateinit var server: MockWebServer
    private lateinit var prefs: InMemorySharedPreferences
    private lateinit var store: TokenStore
    private lateinit var client: SupabaseClient
    private lateinit var lifecycle: SessionLifecycle
    private val dao = FakeCacheDao()
    private val lifecycleScope = CoroutineScope(SupervisorJob() + Dispatchers.Unconfined)
    private val recorded: MutableList<RecordedRequest> = Collections.synchronizedList(mutableListOf())

    @Before
    fun setUp() {
        server = MockWebServer()
        server.start()
        prefs = InMemorySharedPreferences()
        store = TokenStore(prefs)
        lifecycle = SessionLifecycle(store, dao, lifecycleScope, Dispatchers.Unconfined)
        client = SupabaseClient(
            store,
            lifecycle,
            server.url("/").toString().trimEnd('/'),
            "anon-key-for-tests",
            OkHttpClient.Builder().retryOnConnectionFailure(false),
        )
    }

    @After
    fun tearDown() {
        server.shutdown()
        lifecycleScope.cancel()
    }

    // ── helpers ─────────────────────────────────────────

    private fun json(code: Int, body: String) =
        MockResponse().setResponseCode(code).setHeader("Content-Type", "application/json").setBody(body)

    private fun gotrue(code: Int, errorCode: String) = json(code, """{"code":$code,"error_code":"$errorCode","msg":"x"}""")

    private fun html(code: Int) = MockResponse().setResponseCode(code).setBody("<html>$code</html>")

    private fun renewed(access: String, refresh: String) =
        json(200, """{"access_token":"$access","refresh_token":"$refresh","token_type":"bearer","expires_in":3600}""")

    private val userBody = """{"id":"user-A","email":"a@example.test","user_metadata":{"name":"A"},"identities":[]}"""

    private fun install(access: String? = "access-A", refresh: String? = "refresh-A", user: String = "user-A"): String =
        store.installSession(access, refresh, user)!!

    /** Every request is recorded; [handler] answers it. */
    private fun route(handler: (RecordedRequest) -> MockResponse) {
        server.dispatcher = object : Dispatcher() {
            override fun dispatch(request: RecordedRequest): MockResponse {
                recorded += request
                return handler(request)
            }
        }
    }

    private fun RecordedRequest.isRefresh() = path!!.startsWith("/auth/v1/token?grant_type=refresh_token")
    private fun RecordedRequest.bearer() = getHeader("Authorization")
    private fun refreshCount() = recorded.count { it.isRefresh() }

    private fun assertSessionIntact(id: String, access: String, refresh: String) {
        val s = store.snapshot()
        assertNotNull("the session must still be there", s)
        assertEquals(id, s!!.sessionId)
        assertEquals(access, s.accessToken)
        assertEquals(refresh, s.refreshToken)
    }

    /** Ended through the coordinator: credentials gone, and its data deletion already done. */
    private fun assertEnded(id: String, reason: EndReason) {
        assertNull("the session must have ended", store.snapshot())
        assertEquals(reason, store.state.value.endedReason)
        assertNull("the teardown ran inside the end", store.teardownPending)
        assertTrue("clear:dashboard" in dao.calls)
        assertTrue(id.isNotBlank())
    }

    private inline fun <reified T : Throwable> expect(block: () -> Unit): T {
        try {
            block()
        } catch (t: Throwable) {
            if (t is T) return t
            throw AssertionError("expected ${T::class.simpleName}, got $t", t)
        }
        throw AssertionError("expected ${T::class.simpleName}, got no exception")
    }

    // ── classification ──────────────────────────────────

    @Test
    fun `an ordinary 403 is an error and keeps the session`() = runBlocking<Unit> {
        val a = install()
        route { r -> if (r.path == "/auth/v1/user") gotrue(403, "not_admin") else json(403, """{"code":"42501","message":"permission denied"}""") }

        assertEquals(403, expect<ApiError.Http> { client.userIdentities() }.code)
        assertEquals(403, expect<ApiError.Http> { client.sessions() }.code)

        assertEquals("no renewal for a plain 403", 0, refreshCount())
        assertEquals(2, recorded.size)
        assertSessionIntact(a, "access-A", "refresh-A")
    }

    @Test
    fun `bad_jwt renews once and retries with the new token`() = runBlocking<Unit> {
        val a = install()
        route { r ->
            when {
                r.isRefresh() -> renewed("access-A2", "refresh-A2")
                r.bearer() == "Bearer access-A" -> gotrue(403, "bad_jwt")
                else -> json(200, userBody)
            }
        }

        client.userIdentities()

        assertEquals(listOf("Bearer access-A", null, "Bearer access-A2"), recorded.map { it.bearer() })
        assertEquals("""{"refresh_token":"refresh-A"}""", recorded[1].body.readUtf8())
        assertEquals(1, refreshCount())
        assertSessionIntact(a, "access-A2", "refresh-A2")
    }

    @Test
    fun `a PostgREST JWT error renews once and retries`() = runBlocking<Unit> {
        val a = install()
        route { r ->
            when {
                r.isRefresh() -> renewed("access-A2", "refresh-A2")
                r.bearer() == "Bearer access-A" -> json(401, """{"code":"PGRST301","message":"JWSError"}""")
                else -> json(200, "[]")
            }
        }

        assertTrue(client.sessions().isEmpty())

        assertEquals(3, recorded.size)
        assertEquals(1, refreshCount())
        assertSessionIntact(a, "access-A2", "refresh-A2")
    }

    @Test
    fun `session_not_found and user_not_found end the session at once, without a renewal`() = runBlocking<Unit> {
        for (code in listOf("session_not_found", "user_not_found")) {
            recorded.clear()
            val id = install()
            route { r -> if (r.isRefresh()) renewed("x", "y") else gotrue(403, code) }

            expect<ApiError.TokenExpired> { client.userIdentities() }

            assertEquals(code, 1, recorded.size)
            assertEquals(code, 0, refreshCount())
            assertEnded(id, EndReason.SessionGone)
        }
    }

    @Test
    fun `a rejection of the renewed token keeps the session`() = runBlocking<Unit> {
        // The server rejects even the token it has just issued: a signing-key rotation or a
        // proxy, not a verdict on this session. Ending it would sign everyone out at once.
        val id = install()
        route { r ->
            if (r.isRefresh()) renewed("access-A2", "refresh-A2")
            else json(401, """{"code":"PGRST301","message":"JWSError"}""")
        }

        assertEquals(401, expect<ApiError.Http> { client.sessions() }.code)

        assertEquals("request, renewal, retry", 3, recorded.size)
        assertEquals("Bearer access-A2", recorded[2].bearer())
        assertSessionIntact(id, "access-A2", "refresh-A2")
    }

    @Test
    fun `a GoTrue expiry of the renewed token keeps the session too`() = runBlocking<Unit> {
        val id = install()
        route { r -> if (r.isRefresh()) renewed("access-A2", "refresh-A2") else gotrue(403, "bad_jwt") }

        assertEquals(403, expect<ApiError.Http> { client.userIdentities() }.code)

        assertEquals(3, recorded.size)
        assertSessionIntact(id, "access-A2", "refresh-A2")
    }

    @Test
    fun `session_not_found on the retry still ends the session`() = runBlocking<Unit> {
        val id = install()
        route { r ->
            when {
                r.isRefresh() -> renewed("access-A2", "refresh-A2")
                r.bearer() == "Bearer access-A" -> gotrue(403, "bad_jwt")
                else -> gotrue(403, "session_not_found")
            }
        }

        expect<ApiError.TokenExpired> { client.userIdentities() }

        assertEquals(3, recorded.size)
        assertEnded(id, EndReason.SessionGone)
    }

    @Test
    fun `an unrecognisable 401 after a renewal keeps the credentials`() = runBlocking<Unit> {
        val a = install()
        route { r -> if (r.isRefresh()) renewed("access-A2", "refresh-A2") else html(401) }

        assertEquals(401, expect<ApiError.Http> { client.sessions() }.code)

        assertEquals(3, recorded.size)
        assertEquals(1, refreshCount())
        assertSessionIntact(a, "access-A2", "refresh-A2")
    }

    // ── the refresh endpoint ────────────────────────────

    @Test
    fun `a definitive refusal of the renewal ends the session`() = runBlocking<Unit> {
        val refusals = REFRESH_REFUSED_CODES.map { gotrue(400, it) } +
            json(400, """{"error":"invalid_grant","error_description":"Invalid Refresh Token"}""")
        for (refusal in refusals) {
            recorded.clear()
            val id = install()
            route { r -> if (r.isRefresh()) refusal else html(401) }

            expect<ApiError.TokenExpired> { client.sessions() }

            assertEquals("the request, then the refused renewal, no retry", 2, recorded.size)
            assertTrue(recorded[1].isRefresh())
            assertEnded(id, EndReason.SessionRefused)
        }
    }

    @Test
    fun `a failed renewal keeps the session and reports its own error`() = runBlocking<Unit> {
        val failures = listOf(
            gotrue(400, "bad_json"),
            gotrue(429, "over_request_rate_limit"),
            gotrue(400, "some_future_code"),
            json(403, """{"message":"upstream"}"""),
            html(400),
            MockResponse().setResponseCode(408),
            json(500, """{"code":500,"msg":"x"}"""),
            MockResponse().setResponseCode(503),
            html(502),
        )
        for (failure in failures) {
            val id = install()
            server.enqueue(html(401))
            server.enqueue(failure)
            val before = server.requestCount

            val e = expect<Exception> { client.sessions() }

            assertTrue("$failure -> $e", e is ApiError.Http)
            assertEquals("$failure: the request and one renewal attempt, no retry", before + 2, server.requestCount)
            assertSessionIntact(id, "access-A", "refresh-A")
        }
        // Offline: the renewal's connection drops before an answer.
        val id = install()
        server.enqueue(html(401).setHeader("Connection", "close"))
        server.enqueue(MockResponse().setSocketPolicy(SocketPolicy.DISCONNECT_AT_START))

        expect<IOException> { client.sessions() }
        assertSessionIntact(id, "access-A", "refresh-A")
    }

    @Test
    fun `a 200 without both tokens renews nothing and keeps the session`() = runBlocking<Unit> {
        for (answer in listOf(json(200, "{}"), json(200, """{"access_token":"access-new"}"""))) {
            val id = install()
            server.enqueue(html(401))
            server.enqueue(answer)

            assertTrue(expect<Exception> { client.sessions() } is ApiError.Http)
            assertSessionIntact(id, "access-A", "refresh-A")
        }
    }

    @Test
    fun `a renewal that answers with the active pair is accepted`() = runBlocking<Unit> {
        // A repeated use of the parent refresh token (another request used it first): GoTrue
        // answers with the pair that is already active. Nothing is wrong; the session stays.
        val id = install(access = TestJwt.expired(), refresh = "refresh-parent")
        route { r -> if (r.isRefresh()) renewed("access-active", "refresh-active") else json(200, "[]") }

        client.sessions()

        assertSessionIntact(id, "access-active", "refresh-active")
        assertEquals("Bearer access-active", recorded.last().bearer())
    }

    // ── expiry read from the token ──────────────────────

    @Test
    fun `an expired access token is renewed before the request goes out`() = runBlocking<Unit> {
        val id = install(access = TestJwt.expired())
        route { r -> if (r.isRefresh()) renewed("access-A2", "refresh-A2") else json(200, "[]") }

        client.sessions()

        assertEquals(2, recorded.size)
        assertTrue(recorded[0].isRefresh())
        assertEquals("Bearer access-A2", recorded[1].bearer())
        assertSessionIntact(id, "access-A2", "refresh-A2")
    }

    @Test
    fun `a valid or unreadable access token goes out as it is`() = runBlocking<Unit> {
        for (token in listOf(TestJwt.fresh(), "access-not-a-jwt")) {
            recorded.clear()
            install(access = token)
            route { json(200, "[]") }

            client.sessions()

            assertEquals(1, recorded.size)
            assertEquals("Bearer $token", recorded[0].bearer())
        }
    }

    // ── one operation, one session ──────────────────────

    @Test
    fun `me does not send its second request for an account that signed in after its first`() = runBlocking<Unit> {
        install()
        route { r -> if (r.path == "/auth/v1/user") json(200, userBody) else json(200, """[{"name":"Profile A","paired":true}]""") }
        client.afterRequestHook = { path ->
            if (path == "/auth/v1/user") store.installSession("access-B", "refresh-B", "user-B", userName = "Name B")
        }

        expect<ApiError.SessionSuperseded> { client.me() }

        assertEquals("the profiles request was never sent", 1, recorded.size)
        assertFalse(recorded.any { it.bearer() == "Bearer access-B" })
        assertEquals("user-B", store.userId)
        assertEquals("Name B", store.userName)
    }

    @Test
    fun `me writes nothing when the session is signed out between its two requests`() = runBlocking<Unit> {
        val a = install()
        route { json(200, userBody) }
        client.afterRequestHook = { path -> if (path == "/auth/v1/user") store.endIfCurrent(a, EndReason.UserSignedOut) }

        expect<ApiError.SessionSuperseded> { client.me() }

        assertEquals(1, recorded.size)
        assertNull(store.userId)
        assertNull(store.userName)
    }

    @Test
    fun `me stores the profile for its own session`() = runBlocking<Unit> {
        val a = install()
        route { r -> if (r.path == "/auth/v1/user") json(200, userBody) else json(200, """[{"name":"Profile A","email":"a@example.test","paired":true}]""") }

        val me = client.me()

        assertEquals(a, me.sessionId)
        assertEquals("Profile A", store.userName)
        assertEquals("user-A", store.userId)
        assertTrue(me.paired)
    }

    @Test
    fun `an old request that comes back after the next account signed in never uses its tokens`() = runBlocking<Unit> {
        val a = install()
        route { r ->
            when {
                r.isRefresh() -> renewed("should-not", "happen")
                r.path!!.startsWith("/rest/v1/sessions") && r.bearer() == "Bearer access-A" -> {
                    // A signs out and B signs in while A's request is out; A's answer is a 401.
                    store.endIfCurrent(a, EndReason.UserSignedOut)
                    store.installSession("access-B", "refresh-B", "user-B")
                    html(401)
                }
                else -> json(200, "[]")
            }
        }

        expect<ApiError.SessionSuperseded> { client.sessions() }

        assertEquals(1, recorded.size)
        assertEquals(0, refreshCount())
        assertFalse(recorded.any { it.bearer() == "Bearer access-B" || it.body.readUtf8().contains("refresh-B") })
        assertEquals("access-B", store.accessToken)
        assertEquals("refresh-B", store.refreshToken)
    }

    @Test
    fun `a renewal for an ended session never hands out the next account's token`() = runBlocking<Unit> {
        val a = install()
        val ctxA = store.snapshot()!!
        store.endIfCurrent(a, EndReason.UserSignedOut)
        store.installSession("access-B", "refresh-B", "user-B")
        route { renewed("should-not", "happen") }

        expect<ApiError.SessionSuperseded> { client.renew(ctxA, "access-A") }

        assertEquals("no renewal request at all", 0, recorded.size)
        assertEquals("access-B", store.accessToken)
    }

    @Test
    fun `two requests rejected together renew once`() = runBlocking<Unit> {
        val a = install()
        val bothArrived = CountDownLatch(2)
        route { r ->
            when {
                r.isRefresh() -> renewed("access-A2", "refresh-A2")
                r.bearer() == "Bearer access-A" -> {
                    bothArrived.countDown()
                    bothArrived.await(5, TimeUnit.SECONDS)
                    html(401)
                }
                else -> json(200, "[]")
            }
        }

        val results = listOf(
            async(Dispatchers.IO) { client.sessions() },
            async(Dispatchers.IO) { client.sessions() },
        ).awaitAll()

        assertTrue(results.all { it.isEmpty() })
        assertEquals("one renewal for both", 1, refreshCount())
        assertSessionIntact(a, "access-A2", "refresh-A2")
    }

    @Test
    fun `of two overlapping sign-ins the newer one wins, whichever answers last`() = runBlocking<Unit> {
        val olderArrived = CountDownLatch(1)
        val releaseOlder = CountDownLatch(1)
        route { r ->
            val body = r.body.clone().readUtf8()
            when {
                r.path == "/auth/v1/verify" && body.contains("111111") -> {
                    olderArrived.countDown()
                    releaseOlder.await(5, TimeUnit.SECONDS)
                    json(200, """{"access_token":"access-old","refresh_token":"refresh-old","user":{"id":"user-old"}}""")
                }
                r.path == "/auth/v1/verify" ->
                    json(200, """{"access_token":"access-new","refresh_token":"refresh-new","user":{"id":"user-new"}}""")
                else -> json(200, "[]")
            }
        }

        val older = async(Dispatchers.IO) { runCatching { client.verifyOTP("a@example.test", "111111") } }
        assertTrue(olderArrived.await(5, TimeUnit.SECONDS))
        val newer = client.verifyOTP("a@example.test", "222222")
        releaseOlder.countDown()
        val olderResult = older.await()

        assertTrue(olderResult.exceptionOrNull() is ApiError.SessionSuperseded)
        assertEquals(newer.sessionId, store.sessionId)
        assertEquals("access-new", store.accessToken)
        assertEquals("refresh-new", store.refreshToken)
        assertEquals("user-new", store.userId)
    }

    @Test
    fun `a link callback for a session that is no longer current changes nothing`() = runBlocking<Unit> {
        val a = install()
        store.endIfCurrent(a, EndReason.UserSignedOut)
        val b = install(access = "access-B", refresh = "refresh-B", user = "user-B")
        route { json(200, """{"access_token":"access-link","refresh_token":"refresh-link"}""") }

        expect<ApiError.SessionSuperseded> { client.exchangeOAuthCodeForLink("code-1", "verifier-1", a) }

        assertEquals(0, recorded.size)
        assertSessionIntact(b, "access-B", "refresh-B")
    }

    @Test
    fun `a link exchange that answers after the account changed does not land on the next one`() = runBlocking<Unit> {
        val a = install()
        route {
            store.endIfCurrent(a, EndReason.UserSignedOut)
            store.installSession("access-C", "refresh-C", "user-C")
            json(200, """{"access_token":"access-link","refresh_token":"refresh-link"}""")
        }

        expect<ApiError.SessionSuperseded> { client.exchangeOAuthCodeForLink("code-1", "verifier-1", a) }

        assertEquals("access-C", store.accessToken)
        assertEquals("refresh-C", store.refreshToken)
    }

    @Test
    fun `a link exchange for the current session rotates its tokens and keeps its id`() = runBlocking<Unit> {
        val a = install()
        route { json(200, """{"access_token":"access-link","refresh_token":"refresh-link"}""") }

        client.exchangeOAuthCodeForLink("code-1", "verifier-1", a)

        assertSessionIntact(a, "access-link", "refresh-link")
    }

    @Test
    fun `a push token upload for a session that changed is never sent`() = runBlocking<Unit> {
        val a = install()
        store.setDeviceIdIfCurrent(a, "device-A")
        val ctxA = store.snapshot()!!
        // PushService took its snapshot; then the account changed before the upload ran.
        store.endIfCurrent(a, EndReason.UserSignedOut)
        store.installSession("access-B", "refresh-B", "user-B")
        route { json(204, "") }

        expect<ApiError.SessionSuperseded> { client.updatePushToken(ctxA, "device-A", "fcm-token-1") }

        assertEquals(0, recorded.size)
    }

    @Test
    fun `deleting the account ends exactly the session it ran for`() = runBlocking<Unit> {
        val a = install()
        route { r -> if (r.path == "/auth/v1/logout") json(204, "") else json(200, "{}") }

        client.deleteAccount()

        assertEnded(a, EndReason.AccountDeleted)
        assertEquals("/rest/v1/rpc/delete_user_account", recorded[0].path)
        assertEquals("Bearer access-A", recorded.last().bearer())
    }

    @Test
    fun `a delete that answers after the next account signed in leaves that account alone`() = runBlocking<Unit> {
        val a = install()
        route {
            store.endIfCurrent(a, EndReason.UserSignedOut)
            store.installSession("access-B", "refresh-B", "user-B")
            json(200, "{}")
        }

        expect<ApiError.SessionSuperseded> { client.deleteAccount() }

        assertEquals("access-B", store.accessToken)
        assertEquals(1, recorded.size)
    }

    // ── every authenticated entry point renews ──────────

    @Test
    fun `every authenticated entry point renews once on an expiry and then succeeds`() = runBlocking<Unit> {
        data class Entry(val name: String, val rejection: () -> MockResponse, val ok: MockResponse, val call: suspend (SessionContext) -> Unit)

        val gotrueExpiry = { gotrue(403, "bad_jwt") }
        val restExpiry = { json(401, """{"code":"PGRST303","message":"JWT expired"}""") }
        val functionExpiry = { json(401, """{"code":401,"message":"Invalid JWT"}""") }
        val entries = listOf(
            Entry("userIdentities", gotrueExpiry, json(200, userBody)) { client.userIdentities(it) },
            Entry("linkIdentityAuthorizeUrl", gotrueExpiry, json(200, """{"url":"https://example.test/authorize"}""")) {
                client.linkIdentityAuthorizeUrl("github", it)
            },
            Entry("unlinkIdentity", gotrueExpiry, json(200, "{}")) { client.unlinkIdentity("identity-1", it) },
            Entry("registerDevice", restExpiry, json(201, """[{"id":"device-1"}]""")) {
                assertEquals("device-1", client.registerDevice(it, name = "Phone", system = "Android 16"))
            },
            Entry("updatePushToken", restExpiry, json(204, "")) { client.updatePushToken(it, "device-1", "fcm-token-1") },
            Entry("syncProviderQuotas", restExpiry, json(201, "")) {
                client.syncProviderQuotas(it, listOf(SupabaseClient.ProviderQuotaPayload("Claude", remaining = 1, quota = 2)))
            },
            Entry("validateReceipt", functionExpiry, json(200, """{"verified":true,"tier":"pro"}""")) {
                assertEquals(SupabaseClient.ReceiptResult(true, "pro"), client.validateReceipt("purchase-1", "pro_monthly", it))
            },
            Entry("rpc dashboard", restExpiry, json(200, "{}")) { client.dashboard(it) },
            Entry("rpcArray providers", restExpiry, json(200, "[]")) { client.providers(it) },
            Entry("PATCH acknowledgeAlert", restExpiry, json(204, "")) { client.acknowledgeAlert("alert-1", it) },
        )
        for (entry in entries) {
            recorded.clear()
            val id = install()
            route { r ->
                when {
                    r.isRefresh() -> renewed("access-A2", "refresh-A2")
                    r.bearer() == "Bearer access-A" -> entry.rejection()
                    else -> entry.ok
                }
            }

            entry.call(store.snapshot()!!)

            assertEquals(entry.name, listOf("Bearer access-A", null, "Bearer access-A2"), recorded.map { it.bearer() })
            assertSessionIntact(id, "access-A2", "refresh-A2")
        }
    }

    // ── cancellation ────────────────────────────────────

    @Test
    fun `cancelling the caller during a request is a cancellation, not an error, and ends nothing`() = runBlocking<Unit> {
        val a = install()
        val arrived = CountDownLatch(1)
        val release = CountDownLatch(1)
        route { r ->
            if (r.isRefresh()) {
                renewed("should-not", "happen")
            } else {
                arrived.countDown()
                release.await(5, TimeUnit.SECONDS)
                // Without the cancellation check this would renew and retry.
                html(401)
            }
        }
        val thrown = AtomicReference<Throwable?>(null)
        val job = CoroutineScope(Dispatchers.IO).launch {
            try {
                client.sessions()
            } catch (t: Throwable) {
                thrown.set(t)
                throw t
            }
        }
        assertTrue(arrived.await(5, TimeUnit.SECONDS))

        job.cancel()
        release.countDown()
        job.join()

        assertTrue("got ${thrown.get()}", thrown.get() is CancellationException)
        assertEquals("no renewal after the cancellation", 1, recorded.size)
        assertSessionIntact(a, "access-A", "refresh-A")
    }

    @Test
    fun `a request is never sent for a session that already ended`() = runBlocking<Unit> {
        val a = install()
        val ctxA = store.snapshot()!!
        store.endIfCurrent(a, EndReason.UserSignedOut)
        val count = AtomicInteger(0)
        route { count.incrementAndGet(); json(200, "[]") }

        expect<ApiError.SessionSuperseded> { client.sessions(ctxA) }
        assertEquals(0, count.get())
    }

    // ── sign-in generations (one synchronised counter) ──

    private val signInAnswer =
        """{"access_token":"access-new","refresh_token":"refresh-new","user":{"id":"user-new"}}"""

    @Test
    fun `of two overlapping sign-ins the newer one wins when the older answers first`() = runBlocking<Unit> {
        val olderArrived = CountDownLatch(1)
        val releaseOlder = CountDownLatch(1)
        val newerArrived = CountDownLatch(1)
        val releaseNewer = CountDownLatch(1)
        route { r ->
            val body = r.body.clone().readUtf8()
            when {
                r.path == "/auth/v1/verify" && body.contains("111111") -> {
                    olderArrived.countDown()
                    releaseOlder.await(5, TimeUnit.SECONDS)
                    json(200, """{"access_token":"access-old","refresh_token":"refresh-old","user":{"id":"user-old"}}""")
                }
                r.path == "/auth/v1/verify" -> {
                    newerArrived.countDown()
                    releaseNewer.await(5, TimeUnit.SECONDS)
                    json(200, signInAnswer)
                }
                else -> json(200, "[]")
            }
        }

        val older = async(Dispatchers.IO) { runCatching { client.verifyOTP("a@example.test", "111111") } }
        assertTrue(olderArrived.await(5, TimeUnit.SECONDS))
        val newer = async(Dispatchers.IO) { client.verifyOTP("a@example.test", "222222") }
        assertTrue(newerArrived.await(5, TimeUnit.SECONDS))
        releaseOlder.countDown() // the older answers first
        assertTrue(older.await().exceptionOrNull() is ApiError.SessionSuperseded)
        assertNull("the older one installed nothing", store.snapshot())
        releaseNewer.countDown()

        assertEquals(newer.await().sessionId, store.sessionId)
        assertEquals("access-new", store.accessToken)
    }

    @Test
    fun `demo mode entered while a sign-in is out wins over its answer`() = runBlocking<Unit> {
        val arrived = CountDownLatch(1)
        val release = CountDownLatch(1)
        route { r ->
            if (r.path!!.startsWith("/auth/v1/token")) {
                arrived.countDown()
                release.await(5, TimeUnit.SECONDS)
                json(200, signInAnswer)
            } else {
                json(200, "[]")
            }
        }

        val signIn = async(Dispatchers.IO) { runCatching { client.signInWithPassword("a@example.test", "pw-1") } }
        assertTrue(arrived.await(5, TimeUnit.SECONDS))
        val demo = lifecycle.enterDemoMode()
        release.countDown()

        assertTrue(signIn.await().exceptionOrNull() is ApiError.SessionSuperseded)
        assertEquals(demo, store.sessionId)
        assertTrue(store.isDemoMode)
    }

    @Test
    fun `a sign-in cancelled while its request was out installs nothing`() = runBlocking<Unit> {
        val arrived = CountDownLatch(1)
        val release = CountDownLatch(1)
        route { r ->
            if (r.path!!.startsWith("/auth/v1/token")) {
                arrived.countDown()
                release.await(5, TimeUnit.SECONDS)
                json(200, signInAnswer)
            } else {
                json(200, "[]")
            }
        }
        val job = CoroutineScope(Dispatchers.IO).launch { client.signInWithPassword("a@example.test", "pw-1") }
        assertTrue(arrived.await(5, TimeUnit.SECONDS))

        job.cancel()
        release.countDown()
        job.join()

        assertNull(store.snapshot())
        assertEquals("no profile request either", 1, recorded.size)
    }

    @Test
    fun `a browser sign-in callback that arrives after a newer sign-in started installs nothing`() = runBlocking<Unit> {
        val generation = store.beginOAuthLogin(
            TokenStore.PendingOAuthFlow("login", "github", "verifier-1", "state-1", System.currentTimeMillis()),
        )
        val claimed = store.claimPendingOAuthFlow()!!
        // A password sign-in starts while the claimed callback waits to be delivered.
        route { json(400, """{"code":400,"error_code":"invalid_credentials","msg":"x"}""") }
        expect<ApiError.Http> { client.signInWithPassword("a@example.test", "wrong") }
        recorded.clear()
        route { json(200, signInAnswer) }

        expect<ApiError.SessionSuperseded> { client.exchangeOAuthCode("code-1", "verifier-1", claimed.authGeneration) }

        assertEquals(generation, claimed.authGeneration)
        assertEquals("the stale callback is not even exchanged", 0, recorded.size)
        assertNull(store.snapshot())
    }

    @Test
    fun `a browser sign-in callback with its own generation installs`() = runBlocking<Unit> {
        store.beginOAuthLogin(
            TokenStore.PendingOAuthFlow("login", "github", "verifier-1", "state-1", System.currentTimeMillis()),
        )
        val claimed = store.claimPendingOAuthFlow()!!
        route { json(200, signInAnswer) }

        val id = client.exchangeOAuthCode("code-1", "verifier-1", claimed.authGeneration)

        assertEquals(id, store.sessionId)
        assertEquals("access-new", store.accessToken)
    }

    // ── link flows ──────────────────────────────────────

    @Test
    fun `a 1_62 link flow bound at the claim cannot rotate the next account's session`() = runBlocking<Unit> {
        val a = install()
        store.savePendingOAuthFlow(
            TokenStore.PendingOAuthFlow("link", "github", "verifier-1", "state-1", System.currentTimeMillis()),
        )
        val claimed = store.claimPendingOAuthFlow()!!
        store.endIfCurrent(a, EndReason.UserSignedOut)
        val b = install(access = "access-B", refresh = "refresh-B", user = "user-B")
        route { json(200, """{"access_token":"access-link","refresh_token":"refresh-link"}""") }

        expect<ApiError.SessionSuperseded> { client.exchangeOAuthCodeForLink("code-1", "verifier-1", claimed.sessionId!!) }

        assertEquals(a, claimed.sessionId)
        assertEquals(0, recorded.size)
        assertSessionIntact(b, "access-B", "refresh-B")
    }

    @Test
    fun `a link exchange is not sent while a renewal of the same session is out`() = runBlocking<Unit> {
        val a = install()
        val refreshArrived = CountDownLatch(1)
        val releaseRefresh = CountDownLatch(1)
        val linkArrived = CountDownLatch(1)
        val refreshAnswered = java.util.concurrent.atomic.AtomicBoolean(false)
        val linkSentDuringRenewal = java.util.concurrent.atomic.AtomicBoolean(false)
        route { r ->
            when {
                r.isRefresh() -> {
                    refreshArrived.countDown()
                    releaseRefresh.await(5, TimeUnit.SECONDS)
                    refreshAnswered.set(true)
                    renewed("access-R", "refresh-R")
                }
                r.path!!.startsWith("/auth/v1/token?grant_type=pkce") -> {
                    if (!refreshAnswered.get()) linkSentDuringRenewal.set(true)
                    linkArrived.countDown()
                    json(200, """{"access_token":"access-L","refresh_token":"refresh-L"}""")
                }
                r.bearer() == "Bearer access-A" -> html(401)
                else -> json(200, "[]")
            }
        }

        val request = async(Dispatchers.IO) { client.sessions() } // 401, then a renewal
        assertTrue(refreshArrived.await(5, TimeUnit.SECONDS))
        val link = async(Dispatchers.IO) { client.exchangeOAuthCodeForLink("code-1", "verifier-1", a) }
        // Bounded negative wait: with the exchange serialised, it cannot reach the server now.
        val sentEarly = linkArrived.await(1, TimeUnit.SECONDS)
        releaseRefresh.countDown()
        request.await()
        link.await()

        assertFalse("the link exchange went out during the renewal", sentEarly || linkSentDuringRenewal.get())
        assertSessionIntact(a, "access-L", "refresh-L")
    }

    // ── clocks, receipts ────────────────────────────────

    @Test
    fun `a phone clock running ahead does not renew a token it just received`() = runBlocking<Unit> {
        val serverNow = System.currentTimeMillis() / 1000
        val phoneNow = (serverNow + 2 * 3600) * 1000L
        val token = TestJwt.of("""{"sub":"user-a","iat":$serverNow,"exp":${serverNow + 3600}}""")
        store.installSession(token, "refresh-A", "user-A", receivedAtMillis = phoneNow)
        client.nowMillis = { phoneNow + 1000 }
        route { r -> if (r.isRefresh()) renewed("x", "y") else json(200, "[]") }

        client.sessions()
        client.sessions()

        assertEquals("no renewal on every request", 0, refreshCount())
        assertEquals(2, recorded.size)
    }

    @Test
    fun `a receipt check whose renewal fails is a network error, so the tier is kept`() = runBlocking<Unit> {
        install()
        route { r -> if (r.isRefresh()) MockResponse().setResponseCode(503) else json(401, """{"code":401,"message":"Invalid JWT"}""") }

        val result = client.validateReceipt("purchase-1", "pro_monthly")

        assertEquals(SupabaseClient.ReceiptResult(false, "free", isNetworkError = true), result)
    }
}
