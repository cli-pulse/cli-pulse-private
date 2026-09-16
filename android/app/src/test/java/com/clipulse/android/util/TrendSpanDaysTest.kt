package com.clipulse.android.util

import org.junit.Assert.assertEquals
import org.junit.Test

/** The PDF heading states the span it plots instead of a fixed "Last 30 Days". */
class TrendSpanDaysTest {
    @Test
    fun `counts calendar days from first to last date inclusive`() {
        assertEquals(7, PdfReportGenerator.trendSpanDays(listOf("2026-09-11", "2026-09-13", "2026-09-17")))
        assertEquals(1, PdfReportGenerator.trendSpanDays(listOf("2026-09-17")))
        assertEquals(31, PdfReportGenerator.trendSpanDays(listOf("2026-08-18", "2026-09-17")))
    }

    @Test
    fun `nothing plotted is zero, unparseable dates fall back to the count`() {
        assertEquals(0, PdfReportGenerator.trendSpanDays(emptyList()))
        assertEquals(2, PdfReportGenerator.trendSpanDays(listOf("x", "y")))
    }
}
