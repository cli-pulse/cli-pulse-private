package com.clipulse.android.util

import io.sentry.Breadcrumb
import io.sentry.Hint
import io.sentry.SentryEvent
import io.sentry.SentryOptions
import io.sentry.protocol.Message
import io.sentry.protocol.SentryException
import io.sentry.protocol.User
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Test

/**
 * Runs the callbacks `SentryInit.configure` really installs, on real Sentry objects. Every check
 * compares against the exact expected output, so a field that is deleted, left untouched or
 * over-redacted fails, and harmless neighbouring values must survive.
 */
class SentryInitCallbacksTest {
    private val uuid = "1b4e28ba-2fa1-11d2-883f-0016d3cca427"
    private val email = "a.b@example.com"
    private val url = "clipulse://auth/callback?code=abc123&state=xyz"
    private val dirty = "id $uuid mail $email link $url"
    private val clean = "id [id] mail [email] link clipulse://auth/callback?[query]"

    private fun options() = SentryOptions().also { SentryInit.configure(it) }

    private fun send(build: SentryEvent.() -> Unit): SentryEvent =
        options().beforeSend!!.execute(SentryEvent().apply(build), Hint())!!

    @Test
    fun `configure installs both callbacks`() {
        val o = options()
        assertNotNull("beforeSend not installed", o.beforeSend)
        assertNotNull("beforeBreadcrumb not installed", o.beforeBreadcrumb)
    }

    @Test
    fun `breadcrumb message and nested data are redacted exactly`() {
        val crumb = Breadcrumb().apply {
            message = dirty
            setData("plain", dirty)
            setData("nested", mapOf("list" to listOf(mapOf("v" to dirty, "password" to "hunter2", "ok" to "fine"))))
            setData("access_token", "opaque-value")
            setData("count", 3)
        }
        val out = options().beforeBreadcrumb!!.execute(crumb, Hint())!!
        assertEquals(clean, out.message)
        assertEquals(clean, out.data["plain"])
        assertEquals(
            mapOf("list" to listOf(mapOf("v" to clean, "password" to "[scrubbed]", "ok" to "fine"))),
            out.data["nested"],
        )
        assertEquals("[scrubbed]", out.data["access_token"])
        assertEquals(3, out.data["count"])
    }

    @Test
    fun `one breadcrumb through both callbacks is stable`() {
        val o = options()
        val crumb = Breadcrumb().apply {
            message = "https://host/cb?email=$email&code=opaque"
            setData("d", mapOf("u" to "https://host/cb?id=$uuid&code=opaque"))
        }
        val first = o.beforeBreadcrumb!!.execute(crumb, Hint())!!
        val event = SentryEvent().apply { breadcrumbs = listOf(first) }
        val second = o.beforeSend!!.execute(event, Hint())!!.breadcrumbs!![0]
        assertEquals("https://host/cb?[query]", second.message)
        assertEquals(mapOf("u" to "https://host/cb?[query]"), second.data["d"])
    }

    @Test
    fun `event user fields are wiped`() {
        val out = send {
            user = User().apply {
                this.email = "me@example.com"
                ipAddress = "203.0.113.9"
                username = "someone"
            }
        }
        assertNull(out.user!!.email)
        assertNull(out.user!!.ipAddress)
        assertNull(out.user!!.username)
    }

    @Test
    fun `event exception value is redacted`() {
        val out = send { exceptions = listOf(SentryException().apply { value = "HTTP 400: $dirty" }) }
        assertEquals("HTTP 400: $clean", out.exceptions!![0].value)
    }

    @Test
    fun `event message and formatted are redacted`() {
        val out = send { message = Message().apply { formatted = dirty; message = dirty } }
        assertEquals(clean, out.message!!.formatted)
        assertEquals(clean, out.message!!.message)
    }

    @Test
    fun `event message params are redacted and neighbours kept`() {
        val out = send { message = Message().apply { params = listOf(dirty, "plain") } }
        assertEquals(listOf(clean, "plain"), out.message!!.params)
    }

    @Test
    fun `event tag values are redacted and keyed tags scrubbed`() {
        val out = send {
            setTag("who", dirty)
            setTag("platform_family", "android")
            setTag("api_token", "opaque-value")
        }
        assertEquals(clean, out.tags!!["who"])
        assertEquals("android", out.tags!!["platform_family"])
        assertEquals("[scrubbed]", out.tags!!["api_token"])
    }

    @Test
    fun `event extra values are redacted and keyed extras scrubbed`() {
        val out = send {
            setExtra("blob", mapOf("deep" to listOf(dirty, "fine")))
            setExtra("secret_thing", "opaque-value")
        }
        assertEquals(mapOf("deep" to listOf(clean, "fine")), out.extras!!["blob"])
        assertEquals("[scrubbed]", out.extras!!["secret_thing"])
    }

    @Test
    fun `event contexts values are redacted`() {
        val out = send { contexts.put("custom", mapOf("inner" to dirty, "keep" to "fine")) }
        assertEquals(mapOf("inner" to clean, "keep" to "fine"), out.contexts.get("custom"))
    }

    @Test
    fun `event breadcrumbs are redacted again in beforeSend`() {
        val out = send {
            breadcrumbs = listOf(Breadcrumb().apply {
                message = dirty
                setData("d", dirty)
            })
        }
        assertEquals(clean, out.breadcrumbs!![0].message)
        assertEquals(clean, out.breadcrumbs!![0].data["d"])
    }
}
