package com.clipulse.android.util

import io.sentry.Breadcrumb
import io.sentry.Hint
import io.sentry.SentryEvent
import io.sentry.SentryOptions
import io.sentry.protocol.Message
import io.sentry.protocol.SentryException
import io.sentry.protocol.User
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Test

/** Runs the callbacks `SentryInit.configure` really installs, on real Sentry objects. */
class SentryInitCallbacksTest {
    private val uuid = "1b4e28ba-2fa1-11d2-883f-0016d3cca427"
    private val email = "a.b@example.com"
    private val url = "clipulse://auth/callback?code=abc123&state=xyz"
    private val dirty = "id $uuid mail $email link $url"

    private fun options() = SentryOptions().also { SentryInit.configure(it) }

    private fun assertClean(label: String, value: Any?) {
        val text = value.toString()
        assertFalse("$label still has a uuid: $text", text.contains(uuid))
        assertFalse("$label still has an email: $text", text.contains(email))
        assertFalse("$label still has a url query: $text", text.contains("abc123"))
    }

    @Test
    fun `configure installs both callbacks`() {
        val o = options()
        assertNotNull("beforeSend not installed", o.beforeSend)
        assertNotNull("beforeBreadcrumb not installed", o.beforeBreadcrumb)
    }

    @Test
    fun `breadcrumb message and nested data are redacted`() {
        val crumb = Breadcrumb().apply {
            message = dirty
            setData("plain", dirty)
            setData("nested", mapOf("list" to listOf(mapOf("v" to dirty, "password" to "hunter2"))))
            setData("access_token", "opaque-value")
            setData("count", 3)
        }
        val out = options().beforeBreadcrumb!!.execute(crumb, Hint())!!
        assertClean("message", out.message)
        assertClean("data.plain", out.data["plain"])
        assertClean("data.nested", out.data["nested"])
        assertFalse(out.data["nested"].toString().contains("hunter2"))
        assertEquals("[scrubbed]", out.data["access_token"])
        assertEquals(3, out.data["count"])
    }

    private fun send(build: SentryEvent.() -> Unit): SentryEvent =
        options().beforeSend!!.execute(SentryEvent().apply(build), Hint())!!

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
        assertClean("exception", out.exceptions!![0].value)
    }

    @Test
    fun `event message and formatted are redacted`() {
        val out = send { message = Message().apply { formatted = dirty; message = dirty } }
        assertClean("message.formatted", out.message!!.formatted)
        assertClean("message.message", out.message!!.message)
    }

    @Test
    fun `event message params are redacted`() {
        val out = send { message = Message().apply { params = listOf(dirty, "plain") } }
        assertClean("message.params", out.message!!.params)
        assertEquals("plain", out.message!!.params!![1])
    }

    @Test
    fun `event tag values are redacted and keyed tags scrubbed`() {
        val out = send {
            setTag("who", dirty)
            setTag("platform_family", "android")
            setTag("api_token", "opaque-value")
        }
        assertClean("tag value", out.tags!!["who"])
        assertEquals("android", out.tags!!["platform_family"])
        assertEquals("[scrubbed]", out.tags!!["api_token"])
    }

    @Test
    fun `event extra values are redacted and keyed extras scrubbed`() {
        val out = send {
            setExtra("blob", mapOf("deep" to listOf(dirty)))
            setExtra("secret_thing", "opaque-value")
        }
        assertClean("extra", out.extras!!["blob"])
        assertEquals("[scrubbed]", out.extras!!["secret_thing"])
    }

    @Test
    fun `event contexts values are redacted`() {
        val out = send { contexts.put("custom", mapOf("inner" to dirty)) }
        assertClean("contexts", out.contexts.get("custom"))
    }

    @Test
    fun `event breadcrumbs are redacted again in beforeSend`() {
        val out = send {
            breadcrumbs = listOf(Breadcrumb().apply {
                message = dirty
                setData("d", dirty)
            })
        }
        assertClean("event.breadcrumbs message", out.breadcrumbs!![0].message)
        assertClean("event.breadcrumbs data", out.breadcrumbs!![0].data["d"])
    }
}
