package com.clipulse.android.ui.common

import java.net.URI
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Test

class LegalLinksTest {
    @Test
    fun `privacy policy url is the canonical literal`() {
        assertEquals(
            "privacy policy URL must be the canonical Pages address, the same one the Apple apps use",
            "https://cli-pulse.github.io/cli-pulse/privacy.html",
            PRIVACY_POLICY_URL,
        )
    }

    @Test
    fun `privacy policy url parses to the canonical host over https`() {
        val uri = URI(PRIVACY_POLICY_URL)
        assertEquals("https", uri.scheme)
        assertEquals("cli-pulse.github.io", uri.host)
        assertFalse(
            "privacy policy URL must not use the legacy host",
            PRIVACY_POLICY_URL.lowercase().contains("jasonyeyuhe"),
        )
    }
}
