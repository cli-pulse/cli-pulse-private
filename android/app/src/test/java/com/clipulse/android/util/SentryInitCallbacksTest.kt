package com.clipulse.android.util

import io.sentry.Breadcrumb
import io.sentry.Hint
import io.sentry.Message
import io.sentry.SentryEvent
import io.sentry.SentryOptions
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

    @Test
    fun `event fields are redacted and user fields wiped`() {
        val event = SentryEvent().apply {
            user = User().apply {
                this.email = "me@example.com"
                ipAddress = "203.0.113.9"
                username = "someone"
            }
            exceptions = listOf(SentryException().apply { value = "HTTP 400: $dirty" })
            message = Message().apply {
                formatted = dirty
                message = dirty
                params = listOf(dirty, "plain")
            }
            setTag("who", dirty)
            setTag("platform_family", "android")
            setTag("api_token", "opaque-value")
            setExtra("blob", mapOf("deep" to listOf(dirty)))
            setExtra("secret_thing", "opaque-value")
            contexts["custom"] = mapOf("inner" to dirty)
            breadcrumbs = listOf(Breadcrumb().apply {
                message = dirty
                setData("d", dirty)
            })
        }
        val out = options().beforeSend!!.execute(event, Hint())!!

        assertNull(out.user!!.email)
        assertNull(out.user!!.ipAddress)
        assertNull(out.user!!.username)
        assertClean("exception", out.exceptions!![0].value)
        assertClean("message.formatted", out.message!!.formatted)
        assertClean("message.message", out.message!!.message)
        assertClean("message.params", out.message!!.params)
        assertEquals("plain", out.message!!.params!![1])
        assertClean("tag value", out.tags!!["who"])
        assertEquals("android", out.tags!!["platform_family"])
        assertEquals("[scrubbed]", out.tags!!["api_token"])
        assertClean("extra", out.extras!!["blob"])
        assertEquals("[scrubbed]", out.extras!!["secret_thing"])
        assertClean("contexts", out.contexts["custom"])
        assertClean("event.breadcrumbs message", out.breadcrumbs!![0].message)
        assertClean("event.breadcrumbs data", out.breadcrumbs!![0].data["d"])
    }
}
