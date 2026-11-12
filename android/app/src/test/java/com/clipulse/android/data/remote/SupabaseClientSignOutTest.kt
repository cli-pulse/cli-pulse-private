package com.clipulse.android.data.remote

import com.clipulse.android.data.local.FakeCacheDao
import com.clipulse.android.data.session.SessionLifecycle
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.async
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import okhttp3.Interceptor
import okhttp3.MediaType
import okhttp3.OkHttpClient
import okhttp3.Response
import okhttp3.ResponseBody
import okhttp3.mockwebserver.Dispatcher
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import okhttp3.mockwebserver.RecordedRequest
import okhttp3.mockwebserver.SocketPolicy
import okio.BufferedSource
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import java.util.Collections
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicReference

/**
 * Sign Out's server half, [SupabaseClient.revokeSession], against a MockWebServer, with a real
 * TokenStore (whose preferences count every write) holding whatever session is current. The
 * revocation ends the session it is given, and only that one (`scope=local`); renews an
 * expired token first and stores nothing; retries once, only for a refusal of its token;
 * closes every answer; and never throws. OkHttp's own retry is off and an interceptor counts
 * every attempt, so counts are wire attempts. Barriers are latches inside the server's
 * dispatcher; the only timed waits are bounded negative checks.
 */
class SupabaseClientSignOutTest {

    private lateinit var server: MockWebServer
    private lateinit var prefs: InMemorySharedPreferences
    private lateinit var store: TokenStore
    private lateinit var lifecycle: SessionLifecycle
    private lateinit var client: SupabaseClient
    private val lifecycleScope = CoroutineScope(SupervisorJob() + Dispatchers.Unconfined)
    private val recorded: MutableList<RecordedRequest> = Collections.synchronizedList(mutableListOf())
    private val wire = WireRecorder()

    @Before
    fun setUp() {
        server = MockWebServer()
        server.start()
        prefs = InMemorySharedPreferences()
        store = TokenStore(prefs)
        lifecycle = SessionLifecycle(store, FakeCacheDao(), lifecycleScope, Dispatchers.Unconfined)
        client = SupabaseClient(
            store,
            lifecycle,
            server.url("/").toString().trimEnd('/'),
            "anon-key-for-tests",
            OkHttpClient.Builder().retryOnConnectionFailure(false).addInterceptor(wire),
        )
    }

    @After
    fun tearDown() {
        server.shutdown()
        lifecycleScope.cancel()
    }

    // ── helpers ─────────────────────────────────────────

    /** Counts every attempt and wraps every answer's body, so a test can tell whether it was closed. */
    private class WireRecorder : Interceptor {
        val attempts = AtomicInteger()
        val bodies = CopyOnWriteArrayList<ClosingBody>()

        override fun intercept(chain: Interceptor.Chain): Response {
            attempts.incrementAndGet()
            val response = chain.proceed(chain.request())
            val body = response.body ?: return response
            val tracked = ClosingBody(body)
            bodies += tracked
            return response.newBuilder().body(tracked).build()
        }
    }

    private class ClosingBody(private val delegate: ResponseBody) : ResponseBody() {
        @Volatile
        var closed = false
            private set

        override fun contentType(): MediaType? = delegate.contentType()
        override fun contentLength(): Long = delegate.contentLength()
        override fun source(): BufferedSource = delegate.source()
        override fun close() {
            closed = true
            delegate.close()
        }
    }

    private fun json(code: Int, body: String) =
        MockResponse().setResponseCode(code).setHeader("Content-Type", "application/json").setBody(body)

    private fun gotrue(code: Int, errorCode: String) = json(code, """{"code":$code,"error_code":"$errorCode","msg":"x"}""")

    private fun renewed(access: String, refresh: String) =
        json(200, """{"access_token":"$access","refresh_token":"$refresh","token_type":"bearer","expires_in":3600}""")

    private fun noContent() = MockResponse().setResponseCode(204)

    /** A named answer, made fresh for each request. */
    private class Answer(val name: String, val make: () -> MockResponse)

    /** No network: every connection drops before an answer, however many attempts come. */
    private fun offline() {
        server.dispatcher = object : Dispatcher() {
            private fun drop() = MockResponse().setSocketPolicy(SocketPolicy.DISCONNECT_AT_START)
            override fun peek(): MockResponse = drop()
            override fun dispatch(request: RecordedRequest): MockResponse = drop()
        }
    }

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
    private fun RecordedRequest.isLogout() = requestUrl!!.encodedPath == "/auth/v1/logout"
    private fun RecordedRequest.isPkce() = path!!.startsWith("/auth/v1/token?grant_type=pkce")
    private fun RecordedRequest.bearer() = getHeader("Authorization")
    private fun RecordedRequest.bodyText() = body.clone().readUtf8()

    private fun kinds(): List<String> = synchronized(recorded) {
        recorded.map {
            when {
                it.isRefresh() -> "refresh"
                it.isLogout() -> "logout"
                it.isPkce() -> "pkce"
                else -> it.path!!
            }
        }
    }

    private fun ended(access: String?, refresh: String? = "refresh-A", receivedAt: Long? = null) =
        EndedSession("session-A", access, refresh, EndReason.UserSignedOut, receivedAt)

    private fun assertEveryAnswerClosed() {
        assertTrue("no answer was read", wire.bodies.isNotEmpty())
        wire.bodies.forEachIndexed { i, body -> assertTrue("answer $i was left open", body.closed) }
    }

    private fun resetWire() {
        recorded.clear()
        wire.bodies.clear()
        wire.attempts.set(0)
    }

    // ── the request ─────────────────────────────────────

    @Test
    fun `a valid token is one logout with scope=local, and nothing else`() = runBlocking<Unit> {
        val token = TestJwt.fresh()
        route { noContent() }
        val writes = prefs.commits

        client.revokeSession(ended(access = token))

        assertEquals(listOf("logout"), kinds())
        assertEquals(1, wire.attempts.get())
        val logout = recorded[0]
        assertEquals("POST", logout.method)
        // The whole path and query, as sent: this session only, never the default `global`.
        assertEquals("/auth/v1/logout?scope=local", logout.path)
        assertEquals("local", logout.requestUrl!!.queryParameter("scope"))
        assertEquals(setOf("scope"), logout.requestUrl!!.queryParameterNames)
        assertEquals("Bearer $token", logout.bearer())
        assertEquals("anon-key-for-tests", logout.getHeader("apikey"))
        assertEquals("nothing written on the phone", writes, prefs.commits)
        assertEveryAnswerClosed()
    }

    @Test
    fun `an expired token is renewed first with its own refresh token, and the logout carries the new one`() = runBlocking<Unit> {
        val revokedWith = AtomicReference<String?>()
        route { r ->
            when {
                r.isRefresh() -> renewed("access-A2", "refresh-A2")
                r.isLogout() && r.bearer() == "Bearer access-A2" -> {
                    revokedWith.set(r.bearer())
                    noContent()
                }
                else -> gotrue(403, "bad_jwt")
            }
        }
        val writes = prefs.commits

        client.revokeSession(ended(access = TestJwt.expired()))

        assertEquals(listOf("refresh", "logout"), kinds())
        assertTrue(recorded[0].bodyText(), recorded[0].bodyText().contains("\"refresh_token\":\"refresh-A\""))
        assertEquals("/auth/v1/logout?scope=local", recorded[1].path)
        assertEquals("the logout that ends the session went out and was answered 2xx", "Bearer access-A2", revokedWith.get())
        assertEquals("the renewal is not stored", writes, prefs.commits)
        assertNull("nothing installed", store.snapshot())
        assertEveryAnswerClosed()
    }

    @Test
    fun `a token the phone received recently is not renewed first, however fast its clock runs`() = runBlocking<Unit> {
        val serverNow = System.currentTimeMillis() / 1000
        val phoneNow = (serverNow + 2 * 3600) * 1000L
        val token = TestJwt.of("""{"sub":"user-a","iat":$serverNow,"exp":${serverNow + 3600}}""")
        client.nowMillis = { phoneNow + 1000 }
        route { r -> if (r.isRefresh()) renewed("access-A2", "refresh-A2") else noContent() }

        client.revokeSession(ended(access = token, receivedAt = phoneNow))

        assertEquals(listOf("logout"), kinds())
        assertEquals("Bearer $token", recorded[0].bearer())
    }

    @Test
    fun `a refresh token alone is renewed and the logout carries the new token`() = runBlocking<Unit> {
        route { r -> if (r.isRefresh()) renewed("access-A2", "refresh-A2") else noContent() }

        client.revokeSession(ended(access = null))

        assertEquals(listOf("refresh", "logout"), kinds())
        assertEquals("Bearer access-A2", recorded[1].bearer())

        // Refused: there is no token to send a logout with, so nothing else goes out.
        resetWire()
        route { gotrue(400, "refresh_token_not_found") }
        client.revokeSession(ended(access = ""))
        assertEquals(listOf("refresh"), kinds())
    }

    @Test
    fun `nothing to revoke sends nothing`() = runBlocking<Unit> {
        route { noContent() }

        client.revokeSession(EndedSession("session-A", null, null, EndReason.UserSignedOut))
        client.revokeSession(EndedSession("session-A", "", " ", EndReason.UserSignedOut))
        client.revokeSession(EndedSession(TokenStore.DEMO_ID_PREFIX + "1", null, null, EndReason.DemoExit))

        assertEquals(0, wire.attempts.get())
    }

    // ── answers ─────────────────────────────────────────

    @Test
    fun `a logout refused for its token gets one renewal and one retry`() = runBlocking<Unit> {
        val refusals = listOf(
            Answer("403 bad_jwt") { gotrue(403, "bad_jwt") },
            Answer("401 JWT expired") { json(401, """{"code":"PGRST303","message":"JWT expired"}""") },
            Answer("401 without a code") { MockResponse().setResponseCode(401).setBody("<html>401</html>") },
        )
        for (refusal in refusals) {
            val name = refusal.name
            resetWire()
            val token = TestJwt.fresh() // looks valid to the phone; a clock running behind
            route { r ->
                when {
                    r.isRefresh() -> renewed("access-A2", "refresh-A2")
                    r.bearer() == "Bearer access-A2" -> noContent()
                    else -> refusal.make()
                }
            }

            client.revokeSession(ended(access = token))

            assertEquals(name, listOf("logout", "refresh", "logout"), kinds())
            assertEquals(name, "Bearer $token", recorded[0].bearer())
            assertEquals(name, "Bearer access-A2", recorded[2].bearer())
            assertEquals(name, 3, wire.attempts.get())
            assertEveryAnswerClosed()
        }
    }

    @Test
    fun `a second refusal after the retry ends it, three requests in all`() = runBlocking<Unit> {
        route { r -> if (r.isRefresh()) renewed("access-A2", "refresh-A2") else gotrue(403, "bad_jwt") }

        client.revokeSession(ended(access = TestJwt.fresh()))

        assertEquals(listOf("logout", "refresh", "logout"), kinds())
        assertEquals(3, wire.attempts.get())
    }

    @Test
    fun `any other answer to the logout is final, with no renewal and no retry`() = runBlocking<Unit> {
        val answers = listOf(
            Answer("403 not_admin") { gotrue(403, "not_admin") },
            Answer("403 session_not_found") { gotrue(403, "session_not_found") },
            Answer("403 without a code") { json(403, """{"message":"forbidden"}""") },
            Answer("400") { gotrue(400, "validation_failed") },
            Answer("500") { MockResponse().setResponseCode(500) },
            Answer("503") { MockResponse().setResponseCode(503) },
            Answer("204") { noContent() },
        )
        for (answer in answers) {
            val name = answer.name
            resetWire()
            route { r -> if (r.isRefresh()) renewed("access-A2", "refresh-A2") else answer.make() }

            client.revokeSession(ended(access = TestJwt.fresh()))

            assertEquals(name, listOf("logout"), kinds())
            assertEquals(name, 1, wire.attempts.get())
        }
    }

    @Test
    fun `a refused renewal still sends the logout once with the token as it was, and nothing more`() = runBlocking<Unit> {
        val token = TestJwt.expired()
        route { r -> if (r.isRefresh()) gotrue(400, "refresh_token_not_found") else gotrue(403, "bad_jwt") }
        val writes = prefs.commits

        client.revokeSession(ended(access = token)) // and it does not throw

        assertEquals(listOf("refresh", "logout"), kinds())
        assertEquals("Bearer $token", recorded[1].bearer())
        assertEquals(writes, prefs.commits)
        assertEveryAnswerClosed()
    }

    @Test
    fun `offline nothing throws and each request is tried once`() = runBlocking<Unit> {
        val writes = prefs.commits

        offline()

        // A valid token: the logout alone.
        client.revokeSession(ended(access = TestJwt.fresh()))
        assertEquals(1, wire.attempts.get())

        // An expired token: the renewal, then the logout with the token as it was.
        wire.attempts.set(0)
        client.revokeSession(ended(access = TestJwt.expired()))
        assertEquals(2, wire.attempts.get())

        assertEquals(writes, prefs.commits)
    }

    @Test
    fun `every answer the revocation reads is closed, refusals included`() = runBlocking<Unit> {
        // A token refusal, the renewal, a second refusal.
        route { r -> if (r.isRefresh()) renewed("access-A2", "refresh-A2") else gotrue(403, "bad_jwt") }
        client.revokeSession(ended(access = TestJwt.fresh()))
        // A refused renewal, then a server error.
        route { r -> if (r.isRefresh()) gotrue(400, "refresh_token_not_found") else MockResponse().setResponseCode(500) }
        client.revokeSession(ended(access = TestJwt.expired()))
        // A success.
        route { noContent() }
        client.revokeSession(ended(access = TestJwt.fresh()))

        assertEquals(6, wire.bodies.size)
        assertEveryAnswerClosed()
    }

    // ── other sessions ──────────────────────────────────

    @Test
    fun `A's revocation while B signs in uses A's pair only and writes nothing`() = runBlocking<Unit> {
        val accessA = TestJwt.expired()
        val a = lifecycle.install(accessA, "refresh-A", "user-A")!!
        val endedA = lifecycle.endIfCurrent(a, EndReason.UserSignedOut)!!
        val b = AtomicReference<String?>()
        val signInWrites = AtomicInteger(-1)
        val revokedWith = AtomicReference<String?>()
        route { r ->
            when {
                r.isRefresh() -> {
                    // B signs in exactly while A's renewal is out.
                    val before = prefs.commits
                    b.set(runBlocking { lifecycle.install("access-B", "refresh-B", "user-B") })
                    signInWrites.set(prefs.commits - before)
                    renewed("access-A2", "refresh-A2")
                }
                r.isLogout() -> {
                    revokedWith.set(r.bearer())
                    noContent()
                }
                else -> json(200, "[]")
            }
        }
        val writesBefore = prefs.commits

        client.revokeSession(endedA)

        assertEquals(listOf("refresh", "logout"), kinds())
        assertTrue(recorded[0].bodyText().contains("\"refresh_token\":\"refresh-A\""))
        assertEquals("Bearer access-A2", revokedWith.get())
        for (r in recorded) {
            val sent = r.bodyText() + " " + r.bearer()
            assertFalse(sent, sent.contains("access-B") || sent.contains("refresh-B"))
        }
        assertTrue("B signed in during the revocation", signInWrites.get() > 0)
        assertEquals("the revocation itself wrote nothing", writesBefore + signInWrites.get(), prefs.commits)
        assertEquals(b.get(), store.sessionId)
        assertEquals("access-B", store.snapshot()?.accessToken)
        assertEquals("refresh-B", store.snapshot()?.refreshToken)
    }

    /**
     * The background sync's request for A is renewing A (its token has expired) and is held at
     * the server when Sign Out ends A. The revocation waits for that renewal, then renews once
     * with the refresh token it captured, which the held renewal has just spent.
     */
    private fun revokeBesideAWorkerRenewal(revokeRenewalAnswer: () -> MockResponse, expectedLogoutBearer: (accessA: String) -> String) =
        runBlocking<Unit> {
            // Long enough that only the held renewal finishing can release the revocation in time.
            client.revokeWaitMillis = 60_000
            val accessA = TestJwt.expired()
            val a = lifecycle.install(accessA, "refresh-A", "user-A")!!
            val workerRenewalArrived = CountDownLatch(1)
            val releaseWorkerRenewal = CountDownLatch(1)
            val revokeRenewalArrived = CountDownLatch(1)
            val renewals = AtomicInteger()
            val revokedWith = AtomicReference<String?>()
            route { r ->
                when {
                    r.isRefresh() && renewals.incrementAndGet() == 1 -> {
                        workerRenewalArrived.countDown()
                        releaseWorkerRenewal.await(10, TimeUnit.SECONDS)
                        renewed("access-A2", "refresh-A2")
                    }
                    r.isRefresh() -> {
                        revokeRenewalArrived.countDown()
                        revokeRenewalAnswer()
                    }
                    r.isLogout() -> {
                        revokedWith.set(r.bearer())
                        noContent()
                    }
                    else -> json(200, "[]")
                }
            }

            val worker = async(Dispatchers.IO) { runCatching { client.sessions(store.snapshot()) } }
            assertTrue(workerRenewalArrived.await(5, TimeUnit.SECONDS))
            val endedA = lifecycle.endIfCurrent(a, EndReason.UserSignedOut)!! // Sign Out
            val writesAfterEnd = prefs.commits
            val revoke = async(Dispatchers.IO) { client.revokeSession(endedA) }
            var sentBeside = true
            var workerResult: Result<*>? = null
            try {
                // Bounded negative wait: the revocation's renewal must not go out beside the held one.
                sentBeside = revokeRenewalArrived.await(1, TimeUnit.SECONDS)
                releaseWorkerRenewal.countDown()
                // ... and must go out as soon as the held one has finished, whatever its outcome.
                assertTrue(
                    "the revocation was not released when the renewal it waited for finished",
                    revokeRenewalArrived.await(2, TimeUnit.SECONDS),
                )
                revoke.await() // and it does not throw
                workerResult = worker.await()
            } finally {
                releaseWorkerRenewal.countDown()
                revoke.cancel()
            }

            assertFalse("the revocation renewed while the Worker's renewal was out", sentBeside)
            assertEquals(listOf("refresh", "refresh", "logout"), kinds())
            assertTrue(recorded[1].bodyText().contains("\"refresh_token\":\"refresh-A\""))
            assertEquals(expectedLogoutBearer(accessA), revokedWith.get())
            assertTrue(
                "the Worker's renewal is discarded: A has ended",
                workerResult?.exceptionOrNull() is ApiError.SessionSuperseded,
            )
            assertNull("nothing came back to the phone", store.snapshot())
            assertEquals("no store writes after the end", writesAfterEnd, prefs.commits)
        }

    @Test
    fun `beside a Worker renewal of the same session, answered again with the same pair`() =
        revokeBesideAWorkerRenewal({ renewed("access-A2", "refresh-A2") }) { "Bearer access-A2" }

    @Test
    fun `beside a Worker renewal of the same session, refused as already used`() =
        revokeBesideAWorkerRenewal({ gotrue(400, "refresh_token_already_used") }) { accessA -> "Bearer $accessA" }

    @Test
    fun `the wait for that renewal is bounded`() = runBlocking<Unit> {
        client.revokeWaitMillis = 200
        val a = lifecycle.install(TestJwt.expired(), "refresh-A", "user-A")!!
        val workerRenewalArrived = CountDownLatch(1)
        val releaseWorkerRenewal = CountDownLatch(1)
        val logoutArrived = CountDownLatch(1)
        val renewals = AtomicInteger()
        route { r ->
            when {
                r.isRefresh() && renewals.incrementAndGet() == 1 -> {
                    workerRenewalArrived.countDown()
                    releaseWorkerRenewal.await(20, TimeUnit.SECONDS)
                    renewed("access-A2", "refresh-A2")
                }
                r.isRefresh() -> renewed("access-A3", "refresh-A3")
                r.isLogout() -> {
                    logoutArrived.countDown()
                    noContent()
                }
                else -> json(200, "[]")
            }
        }

        val worker = async(Dispatchers.IO) { runCatching { client.sessions(store.snapshot()) } }
        assertTrue(workerRenewalArrived.await(5, TimeUnit.SECONDS))
        val endedA = lifecycle.endIfCurrent(a, EndReason.UserSignedOut)!!
        val revoke = async(Dispatchers.IO) { client.revokeSession(endedA) }
        try {
            assertTrue(
                "the revocation went ahead although that renewal never answered",
                logoutArrived.await(5, TimeUnit.SECONDS),
            )
        } finally {
            releaseWorkerRenewal.countDown()
        }
        revoke.await()
        worker.await()

        assertEquals("Bearer access-A3", recorded.last { it.isLogout() }.bearer())
    }

    @Test
    fun `a renewal of the next account does not hold up the revocation`() = runBlocking<Unit> {
        client.revokeWaitMillis = 30_000
        lifecycle.install(TestJwt.expired("user-b"), "refresh-B", "user-B")!!
        val renewalOfBArrived = CountDownLatch(1)
        val releaseRenewalOfB = CountDownLatch(1)
        val logoutArrived = CountDownLatch(1)
        route { r ->
            when {
                r.isRefresh() -> {
                    renewalOfBArrived.countDown()
                    releaseRenewalOfB.await(20, TimeUnit.SECONDS)
                    renewed("access-B2", "refresh-B2")
                }
                r.isLogout() -> {
                    logoutArrived.countDown()
                    noContent()
                }
                else -> json(200, "[]")
            }
        }

        val requestOfB = async(Dispatchers.IO) { runCatching { client.sessions(store.snapshot()) } }
        assertTrue(renewalOfBArrived.await(5, TimeUnit.SECONDS))
        val revoke = async(Dispatchers.IO) { client.revokeSession(ended(access = TestJwt.fresh())) }
        try {
            assertTrue("A's revocation waited for B's renewal", logoutArrived.await(5, TimeUnit.SECONDS))
        } finally {
            releaseRenewalOfB.countDown()
        }
        revoke.await()
        requestOfB.await()

        assertEquals("access-B2", store.snapshot()?.accessToken)
        assertEquals("refresh-B2", store.snapshot()?.refreshToken)
    }

    // ── one budget ──────────────────────────────────────

    @Test
    fun `the revocation's requests share one time budget, and what it does not cover is not sent`() = runBlocking<Unit> {
        client.revokeBudgetMillis = 500
        val releaseRenewal = CountDownLatch(1)
        route { r ->
            if (r.isRefresh()) {
                releaseRenewal.await(10, TimeUnit.SECONDS) // a renewal that does not answer in time
                renewed("access-A2", "refresh-A2")
            } else {
                noContent()
            }
        }
        try {
            val started = System.nanoTime()
            client.revokeSession(ended(access = TestJwt.expired())) // and it does not throw
            val elapsedMillis = (System.nanoTime() - started) / 1_000_000

            assertTrue("took $elapsedMillis ms with a 500 ms budget", elapsedMillis < 3_000)
            assertEquals("the logout is not sent once the budget is spent", listOf("refresh"), kinds())
            assertEquals(1, wire.attempts.get())
        } finally {
            releaseRenewal.countDown()
        }
    }

    // ── link exchanges ──────────────────────────────────

    /** An access token naming its server session, as GoTrue's do (`session_id`). */
    private fun sessionJwt(serverSession: String) =
        TestJwt.of("""{"sub":"user-a","session_id":"$serverSession","exp":${System.currentTimeMillis() / 1000 + 3600}}""")

    private fun pkceAnswer(access: String) = json(200, """{"access_token":"$access","refresh_token":"refresh-2"}""")

    @Test
    fun `a link exchange revokes the session it replaced on the phone, and only that one`() = runBlocking<Unit> {
        val s1 = sessionJwt("server-1")
        val s2 = sessionJwt("server-2")
        val a = lifecycle.install(s1, "refresh-1", "user-A")!!
        route { r -> if (r.isPkce()) pkceAnswer(s2) else noContent() }
        val writes = prefs.commits

        client.exchangeOAuthCodeForLink("code-1", "verifier-1", a)

        assertEquals(listOf("pkce", "logout"), kinds())
        assertEquals("/auth/v1/logout?scope=local", recorded[1].path)
        assertEquals("Bearer $s1", recorded[1].bearer())
        assertEquals(a, store.sessionId)
        assertEquals(s2, store.snapshot()?.accessToken)
        assertEquals("refresh-2", store.snapshot()?.refreshToken)
        assertEquals("the rotation is the only write", writes + 1, prefs.commits)
    }

    @Test
    fun `a link exchange revokes nothing unless both tokens name two different sessions`() = runBlocking<Unit> {
        for ((before, after) in listOf(
            sessionJwt("server-1") to sessionJwt("server-1"), // the same session kept
            "access-1" to sessionJwt("server-2"), // the old token names none
            sessionJwt("server-1") to "access-2", // the new token names none
        )) {
            resetWire()
            val a = lifecycle.install(before, "refresh-1", "user-A")!!
            route { r -> if (r.isPkce()) pkceAnswer(after) else noContent() }

            client.exchangeOAuthCodeForLink("code-1", "verifier-1", a)

            assertEquals("$before -> $after", listOf("pkce"), kinds())
            assertEquals(after, store.snapshot()?.accessToken)
        }
    }

    @Test
    fun `a sign-out during a link exchange waits for it, and both server sessions are revoked`() = runBlocking<Unit> {
        val s1 = sessionJwt("server-1")
        val s2 = sessionJwt("server-2")
        val a = lifecycle.install(s1, "refresh-1", "user-A")!!
        val exchangeArrived = CountDownLatch(1)
        val releaseExchange = CountDownLatch(1)
        val s1Revoked = CountDownLatch(1)
        val logouts = Collections.synchronizedList(mutableListOf<String?>())
        route { r ->
            when {
                r.isPkce() -> {
                    exchangeArrived.countDown()
                    releaseExchange.await(10, TimeUnit.SECONDS)
                    pkceAnswer(s2)
                }
                r.isLogout() -> {
                    logouts += r.bearer()
                    if (r.bearer() == "Bearer $s1") s1Revoked.countDown()
                    noContent()
                }
                else -> json(500, "{}")
            }
        }

        val link = async(Dispatchers.IO) { runCatching { client.exchangeOAuthCodeForLink("code-1", "verifier-1", a) } }
        assertTrue(exchangeArrived.await(5, TimeUnit.SECONDS))
        val endedA = lifecycle.endIfCurrent(a, EndReason.UserSignedOut)!! // Sign Out
        val writesAfterEnd = prefs.commits
        val revoke = async(Dispatchers.IO) { client.revokeSession(endedA) }
        var revokedBeside = true
        var linkResult: Result<Unit>? = null
        try {
            // Bounded negative wait: the sign-out's logout waits for the exchange still out.
            revokedBeside = s1Revoked.await(1, TimeUnit.SECONDS)
            releaseExchange.countDown()
            revoke.await()
            linkResult = link.await()
        } finally {
            releaseExchange.countDown()
            revoke.cancel()
        }

        assertFalse("the sign-out revoked while the link exchange was out", revokedBeside)
        assertTrue(linkResult?.exceptionOrNull() is ApiError.SessionSuperseded)
        // The sign-out ended S1; the exchange's own S2, never stored, is revoked too.
        assertEquals(setOf("Bearer $s1", "Bearer $s2"), logouts.toSet())
        assertEquals(2, logouts.size)
        assertTrue(recorded.filter { it.isLogout() }.all { it.path == "/auth/v1/logout?scope=local" })
        assertNull(store.snapshot())
        assertEquals("nothing written after the end", writesAfterEnd, prefs.commits)
    }

    @Test
    fun `a link exchange abandoned by its screen stores nothing and revokes the session it made`() = runBlocking<Unit> {
        val s1 = sessionJwt("server-1")
        val s2 = sessionJwt("server-2")
        val a = lifecycle.install(s1, "refresh-1", "user-A")!!
        val exchangeArrived = CountDownLatch(1)
        val releaseExchange = CountDownLatch(1)
        route { r ->
            when {
                r.isPkce() -> {
                    exchangeArrived.countDown()
                    releaseExchange.await(10, TimeUnit.SECONDS)
                    pkceAnswer(s2)
                }
                else -> noContent()
            }
        }

        val link = launch(Dispatchers.IO) { client.exchangeOAuthCodeForLink("code-1", "verifier-1", a) }
        try {
            assertTrue(exchangeArrived.await(5, TimeUnit.SECONDS))
            link.cancel() // the Settings screen went away
        } finally {
            releaseExchange.countDown()
        }
        link.join()

        assertTrue(link.isCancelled)
        assertEquals(listOf("pkce", "logout"), kinds())
        assertEquals("Bearer $s2", recorded[1].bearer())
        assertEquals("nothing stored", s1, store.snapshot()?.accessToken)
        assertEquals("refresh-1", store.snapshot()?.refreshToken)
    }
}
