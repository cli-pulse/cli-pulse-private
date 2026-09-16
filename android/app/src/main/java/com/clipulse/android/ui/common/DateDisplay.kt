package com.clipulse.android.ui.common

import java.time.Instant
import java.time.LocalDate
import java.time.OffsetDateTime
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.time.format.FormatStyle
import java.util.Locale

/**
 * Dates as people read them, in the device's time zone and the app's language.
 *
 * Screens used to print the server's ISO text: a reset time as
 * "2026-09-17T14:00:00+00:00", a device's last sync as the UTC slice
 * "2026-09-17 05:12" (hours off for everyone not in UTC), chart axes as "09-17", and
 * the PDF report's date in English month names whatever the language.
 *
 * Pure java.time, so it runs in JVM unit tests; callers pass the locale from the
 * Compose configuration or the PDF's context, which follow Android's per-app language.
 */
object DateDisplay {

    /** Supabase writes `+00:00` offsets and microseconds; `Instant.parse` on API 26 accepts only `Z`. */
    fun parseInstant(iso: String): Instant? =
        runCatching { OffsetDateTime.parse(iso).toInstant() }.getOrNull()
            ?: runCatching { Instant.parse(iso) }.getOrNull()

    /** "9/17/26, 7:00 PM" / "2026/09/17 19:00", or null when the text is not a timestamp. */
    fun dateTime(iso: String, locale: Locale, zone: ZoneId = ZoneId.systemDefault()): String? =
        parseInstant(iso)?.let {
            DateTimeFormatter.ofLocalizedDateTime(FormatStyle.SHORT).withLocale(locale).withZone(zone).format(it)
        }

    /** A calendar day ("2026-09-17") in the given month/day pattern, or null when it is not one. */
    fun monthDay(isoDate: String, pattern: String, locale: Locale): String? =
        runCatching { LocalDate.parse(isoDate).format(DateTimeFormatter.ofPattern(pattern, locale)) }.getOrNull()

    /** Today's date with its year, for a report header: "September 17, 2026" / "2026年9月17日". */
    fun longDate(date: LocalDate, locale: Locale): String =
        date.format(DateTimeFormatter.ofLocalizedDate(FormatStyle.LONG).withLocale(locale))
}
