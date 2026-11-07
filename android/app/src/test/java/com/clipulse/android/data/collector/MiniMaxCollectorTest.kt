package com.clipulse.android.data.collector

import com.clipulse.android.data.collector.MiniMaxCollector.Companion.parseRemainsResponse
import com.clipulse.android.data.collector.MiniMaxCollector.Parsed
import com.clipulse.android.data.collector.MiniMaxCollector.Window
import com.clipulse.android.data.model.ProviderKind
import kotlinx.coroutines.test.runTest
import okhttp3.mockwebserver.Dispatcher
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import okhttp3.mockwebserver.RecordedRequest
import org.junit.After
import org.junit.Assert.*
import org.junit.Before
import org.junit.Test
import java.time.Instant
import java.util.Collections

/**
 * Mirrors `MiniMaxCollectorTests.swift`. The response shapes are upstream
 * CodexBar's fixtures, which follow what MiniMax sends.
 */
class MiniMaxParsingTest {
    /** 2026-06-01 02:52:20 UTC, inside every window below. */
    private val now = Instant.ofEpochSecond(1_780_282_340)

    private fun parse(json: String) = parseRemainsResponse(json, now)

    private fun windows(parsed: Parsed): Parsed.Windows {
        assertTrue("expected windows, got $parsed", parsed is Parsed.Windows)
        return parsed as Parsed.Windows
    }

    private inline fun <reified T : Throwable> assertThrowsType(block: () -> Unit): T {
        try {
            block()
        } catch (e: Throwable) {
            assertTrue("expected ${T::class.simpleName}, got $e", e is T)
            return e as T
        }
        fail("expected ${T::class.simpleName}")
        throw AssertionError()
    }

    /**
     * The token plan as MiniMax sends it to a Plus account: a `general` lane
     * with a 5-hour and a weekly window, and a video lane the plan does not
     * include (status 3, zero counts, 100 % left).
     */
    private val tokenPlan = """
    {
      "base_resp": { "status_code": 0, "status_msg": "success" },
      "model_remains": [
        {
          "model_name": "video",
          "start_time": 1780243200000, "end_time": 1780329600000,
          "current_interval_total_count": 0, "current_interval_usage_count": 0,
          "current_interval_status": 3, "current_interval_remaining_percent": 100,
          "current_weekly_status": 3, "current_weekly_remaining_percent": 100
        },
        {
          "model_name": "general",
          "start_time": 1780279200000, "end_time": 1780297200000, "remains_time": 14859830,
          "current_interval_total_count": 0, "current_interval_usage_count": 0,
          "current_interval_status": 1, "current_interval_remaining_percent": 96,
          "current_weekly_total_count": 0, "current_weekly_usage_count": 0,
          "weekly_start_time": 1780243200000, "weekly_end_time": 1780848000000,
          "current_weekly_status": 1, "current_weekly_remaining_percent": 99
        }
      ]
    }
    """

    @Test
    fun `token plan reads the general lane and skips the video placeholder`() {
        val w = windows(parse(tokenPlan))
        assertNull(w.plan)
        assertEquals(Window("5-hour", 96, Instant.ofEpochSecond(1_780_297_200), 300), w.interval)
        assertEquals(Window("Weekly", 99, Instant.ofEpochSecond(1_780_848_000), 10080), w.weekly)
    }

    @Test
    fun `token plan builds two percent tiers with the five-hour one as headline`() {
        val result = MiniMaxCollector.buildResult(parse(tokenPlan))
        assertEquals(ProviderKind.MiniMax, result.provider)
        assertEquals(listOf("5-hour", "Weekly"), result.tiers.map { it.name })
        assertEquals(listOf(96, 99), result.tiers.map { it.remaining })
        assertEquals(listOf(100, 100), result.tiers.map { it.quota })
        assertEquals(listOf("2026-06-01T07:00:00Z", "2026-06-07T16:00:00Z"), result.tiers.map { it.resetTime })
        assertEquals(100, result.quota)
        assertEquals(96, result.remaining)
        assertEquals("2026-06-01T07:00:00Z", result.resetTime)
        assertEquals("Coding Plan", result.planType)
    }

    @Test
    fun `data-wrapped string numbers parse the same and name the plan`() {
        val w = windows(parse("""
        {
          "base_resp": { "status_code": "0" },
          "data": {
            "current_subscribe_title": "Token Plan · TokenPlanPlus-年度会员",
            "model_remains": [{
              "model_name": "general",
              "current_interval_total_count": 0, "current_interval_usage_count": 0,
              "current_interval_remaining_percent": "96",
              "start_time": "1780279200000", "end_time": 1780297200000,
              "current_weekly_remaining_percent": "99",
              "weekly_start_time": 1780243200000, "weekly_end_time": 1780848000000
            }]
          }
        }
        """))
        assertEquals("Token Plan · TokenPlanPlus-年度会员", w.plan)
        assertEquals(96, w.interval?.remainingPercent)
        assertEquals("5-hour", w.interval?.name)
        assertEquals(99, w.weekly?.remainingPercent)
        assertEquals("Token Plan · TokenPlanPlus-年度会员", MiniMaxCollector.buildResult(w).planType)
    }

    /** `current_interval_usage_count` is what is LEFT, not what was used. */
    @Test
    fun `count-based coding plan usage count is the remainder`() {
        val w = windows(parse("""
        {"model_remains": [{
          "model_name": "MiniMax-M2",
          "start_time": 1780279200, "end_time": 1780297200,
          "current_interval_total_count": 1500, "current_interval_usage_count": 1200
        }]}
        """))
        assertEquals(80, w.interval?.remainingPercent)
        assertEquals("epoch seconds work like milliseconds", "5-hour", w.interval?.name)
        assertNull(w.weekly)
    }

    @Test
    fun `a media lane first is never read`() {
        val w = windows(parse("""
        {"model_remains": [
          {"model_name": "video", "current_interval_total_count": 100, "current_interval_usage_count": 30,
           "start_time": 1780243200000, "end_time": 1780329600000},
          {"model_name": "speech-hd", "current_interval_total_count": 100, "current_interval_usage_count": 10},
          {"model_name": "M2.5", "current_interval_total_count": 200, "current_interval_usage_count": 150,
           "start_time": 1780243200000, "end_time": 1780329600000}
        ]}
        """))
        assertEquals(75, w.interval?.remainingPercent)
        assertEquals("Daily", w.interval?.name)
        assertEquals(1440, w.interval?.windowMinutes)
    }

    /** A `general` placeholder must not hide a text model that has a quota. */
    @Test
    fun `a general placeholder falls through to a usable text lane`() {
        val w = windows(parse("""
        {"model_remains": [
          {"model_name": "general", "current_interval_status": 3,
           "current_interval_total_count": 0, "current_interval_usage_count": 0,
           "current_interval_remaining_percent": 100},
          {"model_name": "MiniMax-M2", "current_interval_total_count": 100, "current_interval_usage_count": 40}
        ]}
        """))
        assertEquals(40, w.interval?.remainingPercent)
        assertEquals("no start and end: the length is unknown", "Coding Plan", w.interval?.name)
        assertNull(w.interval?.windowMinutes)
    }

    @Test
    fun `an unlimited weekly window is dropped`() {
        val w = windows(parse("""
        {"model_remains": [{
          "model_name": "general", "start_time": 1780279200000, "end_time": 1780297200000,
          "current_interval_remaining_percent": 99,
          "current_weekly_total_count": 0, "current_weekly_usage_count": 0,
          "current_weekly_status": 3, "current_weekly_remaining_percent": 100
        }]}
        """))
        assertEquals(99, w.interval?.remainingPercent)
        assertNull(w.weekly)
    }

    @Test
    fun `weekly only is the headline`() {
        val parsed = parse("""
        {"model_remains": [{
          "model_name": "general",
          "current_weekly_remaining_percent": 35,
          "weekly_start_time": 1780243200000, "weekly_end_time": 1780848000000
        }]}
        """)
        assertNull(windows(parsed).interval)
        val result = MiniMaxCollector.buildResult(parsed)
        assertEquals(listOf("Weekly"), result.tiers.map { it.name })
        assertEquals(35, result.remaining)
        assertEquals("2026-06-07T16:00:00Z", result.resetTime)
    }

    @Test
    fun `percentages are clamped and rounded`() {
        val c = MiniMaxCollector.Companion
        assertEquals(100, c.remainingPercent(120, null, null, null))
        assertEquals(0, c.remainingPercent(-5, null, null, null))
        assertEquals(43, c.remainingPercent("42.5", null, null, null))
        assertEquals(67, c.remainingPercent(null, 3, 2, null))
        assertEquals(100, c.remainingPercent(null, 100, 250, null))
        assertNull("zero total", c.remainingPercent(null, 0, 0, null))
        assertNull("no count", c.remainingPercent(null, 100, null, null))
        assertNull(c.remainingPercent("n/a", null, null, null))
        assertNull("a boolean is not a number", c.remainingPercent(true, null, null, null))
        assertNull("not in this plan", c.remainingPercent(100, 0, 0, 3))
        assertEquals(100, c.remainingPercent(100, 0, 0, 1))
    }

    @Test
    fun `resets prefer an end ahead else the time left`() {
        val c = MiniMaxCollector.Companion
        val ahead = now.plusSeconds(600)
        assertEquals(ahead, c.resetsAt(ahead, 5_000_000, now))
        val past = now.minusSeconds(600)
        assertEquals("a stale end falls back to the milliseconds left", now.plusSeconds(5_000), c.resetsAt(past, 5_000_000, now))
        assertEquals("seconds", now.plusSeconds(900), c.resetsAt(null, 900, now))
        assertNull(c.resetsAt(past, 0, now))
        assertNull("a reset past any sane horizon, not an overflow", c.resetsAt(null, 1e300, now))
        assertNull("not a time", c.date(12345))
        assertNull("not a time either", c.date(1e300))
        assertEquals(c.date(1_780_297_200), c.date(1_780_297_200_000))
    }

    @Test
    fun `base_resp 1004 and invalid api key are a rejected credential`() {
        assertThrowsType<MiniMaxCollector.CredentialRejection> {
            parse("""{"base_resp": {"status_code": 1004, "status_msg": "cookie is missing, log in again"}}""")
        }
        assertThrowsType<MiniMaxCollector.CredentialRejection> {
            parse("""{"base_resp": {"status_code": 2049, "status_msg": "invalid api key"}}""")
        }
    }

    @Test
    fun `another status fails with the code only`() {
        val e = assertThrowsType<MiniMaxCollector.ParseException> {
            parse("""{"base_resp": {"status_code": 1002, "status_msg": "rate limit for user 12345"}}""")
        }
        assertEquals("MiniMax: status 1002", e.message)
    }

    /** A message that only mentions logging in is not a refusal. */
    @Test
    fun `a login service outage is not a rejection`() {
        assertThrowsType<MiniMaxCollector.ParseException> {
            parse("""{"base_resp": {"status_code": 1001, "status_msg": "login service unavailable"}}""")
        }
    }

    /** Finite but too big for an Int: a parse failure or no window, never a crash. */
    @Test
    fun `huge numbers do not crash`() {
        assertThrowsType<MiniMaxCollector.ParseException> { parse("""{"base_resp": {"status_code": "1e100"}}""") }
        assertThrowsType<MiniMaxCollector.ParseException> { parse("""{"model_remains": "1e100", "total": 5}""") }
        val w = windows(parse("""{"model_remains": [{"model_name": "general", "current_interval_remaining_percent": 50, "start_time": 1780279200, "end_time": "1e300", "remains_time": 1e300}]}"""))
        assertEquals(50, w.interval?.remainingPercent)
        assertNull(w.interval?.windowMinutes)
        assertNull(w.interval?.resetsAt)
        assertNull(MiniMaxCollector.toInt(1e100))
        assertEquals(42, MiniMaxCollector.toInt(42.0))
    }

    @Test
    fun `no usable lane is a parse failure`() {
        assertThrowsType<MiniMaxCollector.ParseException> {
            parse("""{"model_remains": [{"model_name": "video", "current_interval_total_count": 10, "current_interval_usage_count": 5}]}""")
        }
        assertThrowsType<MiniMaxCollector.ParseException> { parse("""{"model_remains": []}""") }
        assertThrowsType<MiniMaxCollector.ParseException> { parse("""{"base_resp": {"status_code": 0}}""") }
        assertThrowsType<MiniMaxCollector.ParseException> { parse("bad") }
    }

    /** What this collector used to read (`data.remaining`) is no quota at all. */
    @Test
    fun `the shape the old Android collector guessed is not read as 0 percent left`() {
        assertThrowsType<MiniMaxCollector.ParseException> { parse("""{"data": {"remaining": 0, "quota": 100}}""") }
    }

    /** The flat shape the Mac collector used to expect still parses. */
    @Test
    fun `the old flat shape still parses`() {
        assertEquals(Parsed.Legacy(800, 1000, "2026-05-01T00:00:00Z"),
            parse("""{"model_remains":800,"total":1000,"end_time":"2026-05-01T00:00:00Z"}"""))
        val zero = parse("""{"model_remains":0,"total":500}""")
        assertEquals(Parsed.Legacy(0, 500, null), zero)
        val result = MiniMaxCollector.buildResult(zero)
        assertEquals(listOf(CollectorTier("Coding Plan", 500, 0, null)), result.tiers)
        assertEquals(500, result.quota)
    }
}

class MiniMaxFetchTest {
    private lateinit var global: MockWebServer
    private lateinit var china: MockWebServer

    /** "global/v1/token_plan/remains" etc., in the order asked. */
    private val asked: MutableList<String> = Collections.synchronizedList(mutableListOf())
    private val keys: MutableList<String> = Collections.synchronizedList(mutableListOf())

    private val ok = """{"model_remains":[{"model_name":"general","current_interval_remaining_percent":70}]}"""

    private fun answer(status: Int, body: String = "") = MockResponse().setResponseCode(status).setBody(body)

    /** Routes both servers through one handler: (region, request) -> reply. */
    private fun route(handler: (region: String, request: RecordedRequest) -> MockResponse) {
        for ((name, server) in listOf("global" to global, "china" to china)) {
            server.dispatcher = object : Dispatcher() {
                override fun dispatch(request: RecordedRequest): MockResponse {
                    asked.add("$name${request.path}")
                    keys.add("$name ${request.getHeader("Authorization")}")
                    return handler(name, request)
                }
            }
        }
    }

    private fun collector() = MiniMaxCollector(
        globalBaseUrl = global.url("/").toString().trimEnd('/'),
        chinaBaseUrl = china.url("/").toString().trimEnd('/'),
        now = { Instant.ofEpochSecond(1_780_282_340) },
    )

    private inline fun <reified T : Throwable> assertFails(block: () -> Unit): T {
        try {
            block()
        } catch (e: Throwable) {
            assertTrue("expected ${T::class.simpleName}, got $e", e is T)
            return e as T
        }
        fail("expected ${T::class.simpleName}")
        throw AssertionError()
    }

    @Before
    fun setUp() {
        MiniMaxCollector.resetRememberedRegion()
        global = MockWebServer().apply { start() }
        china = MockWebServer().apply { start() }
    }

    @After
    fun tearDown() {
        MiniMaxCollector.resetRememberedRegion()
        global.shutdown()
        china.shutdown()
    }

    @Test
    fun `availability and kind`() {
        val c = collector()
        assertEquals(ProviderKind.MiniMax, c.kind)
        assertTrue(c.isAvailable("key"))
        assertFalse(c.isAvailable(null))
        assertFalse(c.isAvailable("  "))
    }

    @Test
    fun `the default hosts are the global and China mainland APIs`() {
        val c = MiniMaxCollector()
        assertEquals("https://api.minimax.io", c.globalBaseUrl)
        assertEquals("https://api.minimaxi.com", c.chinaBaseUrl)
    }

    @Test
    fun `a global key is answered by the first path`() = runTest {
        route { _, _ -> answer(200, ok) }
        val result = collector().collect(" k ")
        assertEquals(70, result.remaining)
        assertEquals(listOf("global/v1/token_plan/remains"), asked)
        assertEquals(listOf("global Bearer k"), keys)
        assertEquals("CLIPulseBar", global.takeRequest().getHeader("MM-API-Source"))
    }

    @Test
    fun `a China key is asked in China after global rejects it, and China is remembered first`() {
        route { region, _ -> if (region == "china") answer(200, ok) else answer(401) }
        val first = collector().fetchWithApiKey("k")
        assertEquals(70, MiniMaxCollector.buildResult(first).remaining)
        assertEquals(listOf(
            "global/v1/token_plan/remains",
            "global/v1/api/openplatform/coding_plan/remains",
            "china/v1/token_plan/remains",
        ), asked)

        asked.clear()
        collector().fetchWithApiKey("k")
        assertEquals("the region that answered goes first", listOf("china/v1/token_plan/remains"), asked)
    }

    /** A new key starts on the global host, so a global key is never sent to China first. */
    @Test
    fun `another key starts on the global host again`() {
        route { region, r ->
            val key = r.getHeader("Authorization")
            val good = if (region == "china") "Bearer china" else "Bearer global"
            if (key == good) answer(200, ok) else answer(401)
        }
        collector().fetchWithApiKey("china")
        asked.clear(); keys.clear()
        collector().fetchWithApiKey("global")
        assertEquals(listOf("global/v1/token_plan/remains"), asked)
        assertFalse(keys.contains("china Bearer global"))
        asked.clear()
        collector().fetchWithApiKey("china")
        assertEquals("the china key still goes to China first", listOf("china/v1/token_plan/remains"), asked)
    }

    /** Upstream's case: the token plan refuses the key and the old path does not exist there. */
    @Test
    fun `rejected then missing still counts as rejected`() {
        route { region, r ->
            when {
                region == "china" -> answer(200, ok)
                r.path == "/v1/token_plan/remains" -> answer(403)
                else -> answer(404)
            }
        }
        collector().fetchWithApiKey("k")
        assertEquals("china/v1/token_plan/remains", asked.last())
    }

    @Test
    fun `a global outage does not send the key to China`() {
        route { _, _ -> answer(503) }
        val e = assertFails<MiniMaxCollector.HttpStatusException> { collector().fetchWithApiKey("k") }
        assertEquals(503, e.status)
        assertEquals(0, china.requestCount)
    }

    @Test
    fun `a rejection beside an outage is not called rejected`() {
        route { _, r ->
            if (r.path == "/v1/token_plan/remains") answer(401)
            else MockResponse().setSocketPolicy(okhttp3.mockwebserver.SocketPolicy.DISCONNECT_AFTER_REQUEST)
        }
        assertFails<java.io.IOException> { collector().fetchWithApiKey("k") }
        assertEquals(0, china.requestCount)
    }

    @Test
    fun `a China outage after a global rejection is an outage, not a rejection`() {
        route { region, _ -> if (region == "china") answer(502) else answer(401) }
        val e = assertFails<MiniMaxCollector.HttpStatusException> { collector().fetchWithApiKey("k") }
        assertEquals(502, e.status)
    }

    @Test
    fun `both regions rejecting is a rejected key`() {
        route { _, _ -> answer(200, """{"base_resp":{"status_code":1004}}""") }
        assertFails<MiniMaxCollector.KeyRejectedException> { collector().fetchWithApiKey("k") }
        assertEquals(4, asked.size)
    }

    @Test
    fun `an unreadable answer is an outage, not a rejection`() {
        route { _, _ -> answer(200, "<html>maintenance</html>") }
        assertFails<MiniMaxCollector.ParseException> { collector().fetchWithApiKey("k") }
        assertEquals(0, china.requestCount)
    }

    @Test
    fun `a missing token plan path falls back to the coding plan path`() {
        route { _, r -> if (r.path == "/v1/token_plan/remains") answer(404) else answer(200, ok) }
        collector().fetchWithApiKey("k")
        assertEquals(listOf("global/v1/token_plan/remains", "global/v1/api/openplatform/coding_plan/remains"), asked)
    }

    @Test
    fun `a redirect is not followed`() {
        route { region, _ ->
            if (region == "china") answer(200, ok)
            else answer(302).addHeader("Location", china.url("/steal").toString())
        }
        val e = assertFails<MiniMaxCollector.HttpStatusException> { collector().fetchWithApiKey("k") }
        assertEquals("the refused redirect ends the request", 302, e.status)
        assertEquals("the Bearer header followed a redirect", 0, china.requestCount)
    }
}
