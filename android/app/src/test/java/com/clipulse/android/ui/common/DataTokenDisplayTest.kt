package com.clipulse.android.ui.common

import com.clipulse.android.R
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/**
 * Which label a stored token gets. The labels themselves are string resources, which
 * JVM tests cannot resolve, so this pins the ids — and that a token we do not know
 * gets no id, so the screen shows it as it arrived rather than a wrong word.
 */
class DataTokenDisplayTest {

    @Test
    fun `session statuses include the server's Ended, which SessionStatus lacks`() {
        assertEquals(R.string.session_status_running, DataTokenDisplay.sessionStatus("Running"))
        assertEquals(R.string.session_status_ended, DataTokenDisplay.sessionStatus("Ended"))
    }

    @Test
    fun `matching ignores case and surrounding space`() {
        assertEquals(R.string.account_tier_pro, DataTokenDisplay.accountTier("pro"))
        assertEquals(R.string.account_tier_pro, DataTokenDisplay.accountTier(" PRO "))
        assertEquals(R.string.alert_severity_info, DataTokenDisplay.severity("INFO"))
    }

    @Test
    fun `device statuses and webhook types`() {
        assertEquals(R.string.device_status_degraded, DataTokenDisplay.deviceStatus("Degraded"))
        assertEquals(R.string.webhook_type_session_long, DataTokenDisplay.webhookType("session_long"))
    }

    @Test
    fun `unknown and missing tokens get no label`() {
        assertNull(DataTokenDisplay.sessionStatus("Paused"))
        assertNull(DataTokenDisplay.deviceStatus(null))
        assertNull(DataTokenDisplay.accountTier(""))
        assertNull(DataTokenDisplay.webhookType("cost spike"))
    }

    @Test
    fun `every severity the webhook filter offers has a label`() {
        for (severity in listOf("Critical", "Warning", "Info")) {
            assertEquals(true, DataTokenDisplay.severity(severity) != null)
        }
    }
}
