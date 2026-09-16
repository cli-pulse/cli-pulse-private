package com.clipulse.android.ui.components

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test
import java.time.Instant

/**
 * The reset countdown used to be English built in Kotlin ("Resets in 3h 12m"). The
 * words now come from string resources in Compose, which JVM tests cannot resolve, so
 * this pins the part that decides WHICH sentence a tier shows.
 */
class ResetCountdownTest {
    private val now = Instant.parse("2026-09-17T10:00:00Z")

    @Test
    fun `hours and minutes`() {
        assertEquals(
            ResetCountdown.InHoursAndMinutes(3, 12),
            resetCountdown("2026-09-17T13:12:30Z", now),
        )
    }

    @Test
    fun `minutes only under an hour`() {
        assertEquals(ResetCountdown.InMinutes(45), resetCountdown("2026-09-17T10:45:00Z", now))
    }

    @Test
    fun `under a minute is soon`() {
        assertEquals(ResetCountdown.Soon, resetCountdown("2026-09-17T10:00:40Z", now))
    }

    @Test
    fun `a reset time in the past is resetting`() {
        assertEquals(ResetCountdown.Resetting, resetCountdown("2026-09-17T09:59:00Z", now))
    }

    @Test
    fun `whole hours keep a zero minute part`() {
        assertEquals(ResetCountdown.InHoursAndMinutes(2, 0), resetCountdown("2026-09-17T12:00:00Z", now))
    }

    @Test
    fun `missing or unparseable time shows nothing`() {
        assertNull(resetCountdown(null, now))
        assertNull(resetCountdown("", now))
        assertNull(resetCountdown("tomorrow", now))
    }
}
