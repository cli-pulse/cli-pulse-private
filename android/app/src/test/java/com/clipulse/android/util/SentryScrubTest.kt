package com.clipulse.android.util

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class SentryScrubTest {
    private fun redact(s: String) = SentryScrub.redact(s)

    @Test
    fun `uuid is replaced`() {
        assertEquals(
            """HTTP 400: {"user_id":"[id]"}""",
            redact("""HTTP 400: {"user_id":"1b4e28ba-2fa1-11d2-883f-0016d3cca427"}"""),
        )
    }

    @Test
    fun `email is replaced`() {
        assertEquals("x [email] y", redact("x a.b@example.com y"))
    }

    @Test
    fun `existing secret patterns still apply`() {
        val jwt = "eyJhbGciOiJIUzI1.eyJzdWIiOiIxMjM0NTY3.SflKxwRJSMeKKF2QT4"
        assertEquals("a [scrubbed] b", redact("a $jwt b"))
        assertEquals("k=[scrubbed]", redact("k=sk-abcdefghijklmnopqrstuvwxyz"))
        // The literal is split so secret scanners do not flag the vector.
        assertEquals("[scrubbed]", redact("sk_" + "live_abcdefghijklmnop1234"))
        assertEquals("h: [scrubbed]", redact("h: Bearer abc.def-123="))
    }

    @Test
    fun `query of a custom scheme url is dropped`() {
        assertEquals(
            "clipulse://auth/callback?[query]",
            redact("clipulse://auth/callback?code=abc123&state=xyz"),
        )
    }

    @Test
    fun `fragment of an https url is dropped`() {
        val out = redact("https://host/cb#access_token=opaque")
        assertEquals("https://host/cb#[query]", out)
        assertFalse(out.contains("opaque"))
    }

    @Test
    fun `opaque token in a query inside exception text is dropped to the next space`() {
        val out = redact("failed (https://host/cb?code=Zq9opaque,keep;me&x=1) while exchanging")
        // A ")" touching the URL is part of the query as far as the scanner can tell, so it goes too.
        assertEquals("failed (https://host/cb?[query] while exchanging", out)
    }

    @Test
    fun `brackets parentheses and braces inside a query do not end the redaction`() {
        for (q in listOf("next=(ok)&code=opaque", "a=[x]&code=opaque", "a={x}&code=opaque", "a=)&b=]&c=}&code=opaque")) {
            val out = redact("https://host/cb?$q")
            assertEquals("https://host/cb?[query]", out)
            assertEquals("second pass: $q", out, redact(out))
        }
        assertEquals("https://host/cb#[query]", redact("https://host/cb#a=(1)&code=opaque"))
    }

    @Test
    fun `quotes and angle brackets inside a query do not end the redaction`() {
        for (q in listOf("next='ok'&code=opaque", "next=\"ok\"&code=opaque", "a=<x>&code=opaque", "a=%27&b='&c=\"&code=opaque")) {
            val out = redact("https://host/cb?$q")
            assertEquals("https://host/cb?[query]", out)
            assertEquals("second pass: $q", out, redact(out))
        }
        assertEquals("https://host/cb#[query]", redact("https://host/cb#a='1'&code=opaque"))
        // Over-redaction accepted: JSON closing punctuation touching the URL goes with the query.
        assertEquals("""{"u":"https://host/cb?[query]""", redact("""{"u":"https://host/cb?a=1"}"""))
    }

    @Test
    fun `the cap and a second pass agree`() {
        val long = "https://host/cb?code=" + "x".repeat(20000)
        val once = redact(long)
        assertEquals("https://host/cb?[query]", once.removeSuffix("[truncated]").ifEmpty { once })
        assertEquals(once, redact(once))
    }

    @Test
    fun `a left boundary keeps sk and Bearer matches to whole tokens`() {
        assertEquals("disk-encryption-configuration", redact("disk-encryption-configuration"))
        assertEquals("task-abcdefghijklmnopqrstuvwxyz", redact("task-abcdefghijklmnopqrstuvwxyz"))
        assertEquals("[scrubbed]", redact("sk-abcdefghijklmnopqrstuvwxyz"))
        assertEquals("a [scrubbed]", redact("a Bearer abc.def"))
        assertEquals("NoBearer token", redact("NoBearer token"))
    }

    @Test(timeout = 10000)
    fun `very long inputs are cut and stay fast`() {
        val noise = "a.b-c+d".repeat(40000)
        val out = redact("https://" + noise + " x@" + noise)
        assertTrue(out.endsWith("[truncated]"))
        assertTrue(out.length < SentryScrub.MAX_REDACT_CHARS + 64)
        redact("a@".repeat(100000))
        redact("http://".repeat(100000))
    }

    @Test
    fun `secret-like values followed by an opaque parameter leave nothing behind`() {
        assertEquals("https://host/cb?[query]", redact("https://host/cb?email=a@b.com&code=opaque"))
        assertEquals(
            "https://host/cb?[query]",
            redact("https://host/cb?id=1b4e28ba-2fa1-11d2-883f-0016d3cca427&code=opaque"),
        )
        assertEquals(
            "https://host/cb?[query]",
            redact("https://host/cb?k=sk-abcdefghijklmnopqrstuvwxyz&code=opaque"),
        )
        assertEquals("https://host/cb#[query]", redact("https://host/cb#email=a@b.com&code=opaque"))
    }

    @Test
    fun `a placeholder followed by more query text is not exempt`() {
        assertEquals("https://host/cb?[query]", redact("https://host/cb?[query]&code=opaque"))
        assertEquals("https://host/cb?[query]", redact("https://host/cb?[query])&code=opaque"))
    }

    @Test
    fun `second pass changes nothing`() {
        for (s in listOf(
            "https://host/cb?email=a@b.com&code=opaque",
            "https://host/cb?id=1b4e28ba-2fa1-11d2-883f-0016d3cca427&code=opaque",
            "see [https://host/cb?code=1] and a@b.com",
            "https://host/cb?next=(ok)&code=opaque",
        )) {
            val once = redact(s)
            assertEquals(once, redact(once))
        }
        assertEquals("see [https://host/cb?[query] and [email]", redact("see [https://host/cb?code=1] and a@b.com"))
    }

    @Test
    fun `redaction is idempotent`() {
        val once = redact("clipulse://auth/callback?code=abc123 and a@b.com and 1b4e28ba-2fa1-11d2-883f-0016d3cca427")
        assertEquals(once, redact(once))
    }

    @Test
    fun `harmless text is kept`() {
        for (s in listOf(
            "cli-pulse@1.62.0+83",
            "rpc/app_dashboard_summary_v2",
            "https://host/path",
            "plain words here",
            "12345 and 3.14",
            "deadbeef cafe",
        )) assertEquals(s, redact(s))
    }

    @Test
    fun `non-string leaves are unchanged`() {
        assertEquals(42, SentryScrub.scrubValue("count", 42))
        assertEquals(true, SentryScrub.scrubValue("flag", true))
        assertEquals(null, SentryScrub.scrubValue("none", null))
    }

    @Test
    fun `keyed value is scrubbed at the top level`() {
        assertEquals("[scrubbed]", SentryScrub.scrubValue("access_token", "anything"))
    }

    @Test
    fun `nested map list map is scrubbed at depth four`() {
        val uuid = "1b4e28ba-2fa1-11d2-883f-0016d3cca427"
        val input = mapOf(
            "l1" to mapOf(
                "l2" to listOf(
                    mapOf("password" to "hunter2", "note" to "id $uuid", "n" to 7),
                ),
            ),
        )
        @Suppress("UNCHECKED_CAST")
        val out = SentryScrub.scrubValue("root", input) as Map<String, Any?>
        val l2 = (out["l1"] as Map<*, *>)["l2"] as List<*>
        val leaf = l2[0] as Map<*, *>
        assertEquals("keyed value inside nesting must be scrubbed", "[scrubbed]", leaf["password"])
        assertEquals("uuid inside nesting must be redacted", "id [id]", leaf["note"])
        assertEquals(7, leaf["n"])
    }

    @Test
    fun `keyed value inside a nested map is scrubbed`() {
        @Suppress("UNCHECKED_CAST")
        val out = SentryScrub.scrubValue("root", mapOf("a" to mapOf("api_key" to "opaque", "ok" to "x"))) as Map<String, Any?>
        val inner = out["a"] as Map<*, *>
        assertEquals("keyed filtering must apply below the top level", "[scrubbed]", inner["api_key"])
        assertEquals("x", inner["ok"])
    }

    @Test
    fun `strings inside a list are redacted`() {
        val out = SentryScrub.scrubValue("root", mapOf("items" to listOf("a@b.com", "plain"))) as Map<*, *>
        assertEquals("strings below the first level must be redacted", listOf("[email]", "plain"), out["items"])
    }

    @Test
    fun `array elements are scrubbed`() {
        val out = SentryScrub.scrubValue("k", arrayOf("a@b.com", "ok")) as List<*>
        assertEquals(listOf("[email]", "ok"), out)
    }

    @Test(timeout = 5000)
    fun `self referencing map terminates`() {
        val m = HashMap<String, Any?>()
        m["self"] = m
        m["ok"] = "fine"
        @Suppress("UNCHECKED_CAST")
        val out = SentryScrub.scrubValue("k", m) as Map<String, Any?>
        assertEquals("[truncated]", out["self"])
        assertEquals("fine", out["ok"])
    }

    @Test(timeout = 5000)
    fun `a twenty deep chain truncates at the limit`() {
        var node: Map<String, Any?> = mapOf("end" to "leaf")
        repeat(20) { node = mapOf("n" to node) }
        var cur: Any? = SentryScrub.scrubValue("k", node)
        var hops = 0
        while (cur is Map<*, *>) {
            cur = cur["n"]
            hops++
        }
        assertEquals("[truncated]", cur)
        // The root map is depth 0; the map at depth MAX_DEPTH + 1 is replaced.
        assertEquals(SentryScrub.MAX_DEPTH + 1, hops)
    }

    @Test
    fun `shared non cyclic nodes are not truncated`() {
        val shared = mapOf("v" to "x")
        val out = SentryScrub.scrubValue("k", listOf(shared, shared)) as List<*>
        assertTrue(out.all { it is Map<*, *> })
    }
}
