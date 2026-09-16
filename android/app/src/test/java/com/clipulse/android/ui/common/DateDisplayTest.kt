package com.clipulse.android.ui.common

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.time.Instant
import java.time.LocalDate
import java.time.ZoneId
import java.util.Locale

/**
 * Exact localized output varies with the JDK's CLDR data, so these assert the parts
 * that matter (the zone conversion, the language, no raw ISO) rather than whole strings.
 */
class DateDisplayTest {

    @Test
    fun `parses the offsets and fractions Supabase writes`() {
        val expected = Instant.parse("2026-09-17T10:00:00Z")
        assertEquals(expected, DateDisplay.parseInstant("2026-09-17T10:00:00Z"))
        assertEquals(expected, DateDisplay.parseInstant("2026-09-17T10:00:00+00:00"))
        assertEquals(expected, DateDisplay.parseInstant("2026-09-17T19:00:00+09:00"))
        assertEquals(Instant.parse("2026-09-17T10:00:00.123456Z"), DateDisplay.parseInstant("2026-09-17T10:00:00.123456+00:00"))
        assertNull(DateDisplay.parseInstant("tomorrow"))
    }

    @Test
    fun `converts to the device zone instead of printing UTC`() {
        val tokyo = DateDisplay.dateTime("2026-09-17T10:00:00+00:00", Locale.JAPAN, ZoneId.of("Asia/Tokyo"))!!
        assertTrue(tokyo, tokyo.contains("19:00"))
        assertFalse(tokyo, tokyo.contains("T"))
        val newYork = DateDisplay.dateTime("2026-09-17T10:00:00+00:00", Locale.US, ZoneId.of("America/New_York"))!!
        assertTrue(newYork, newYork.contains("6:00"))
        assertNull(DateDisplay.dateTime("not a time", Locale.US))
    }

    @Test
    fun `month and day follow the pattern and language`() {
        assertEquals("9/17", DateDisplay.monthDay("2026-09-17", "M/d", Locale.US))
        assertEquals("9月17日", DateDisplay.monthDay("2026-09-17", "M月d日", Locale.JAPAN))
        assertNull(DateDisplay.monthDay("2026-9-17x", "M/d", Locale.US))
    }

    @Test
    fun `the report date is written in the report's language`() {
        val day = LocalDate.of(2026, 9, 17)
        assertTrue(DateDisplay.longDate(day, Locale.US).contains("September"))
        val japanese = DateDisplay.longDate(day, Locale.JAPAN)
        assertTrue(japanese, japanese.contains("9月17日"))
        assertFalse(japanese, japanese.contains("September"))
    }
}
