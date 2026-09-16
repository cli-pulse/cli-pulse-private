package com.clipulse.android.ui.alerts

import com.clipulse.android.data.model.AlertRecord
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/**
 * Classification of real producer text into alert kinds. The fixtures are the exact
 * strings the macOS AlertGenerator, the Python helper and the Tauri desktop app write
 * (the same fixtures Apple's AlertPresentationTests uses). The words are resources,
 * rendered in Compose, which JVM tests cannot resolve.
 */
class AlertPresentationTest {

    private fun record(id: String, type: String, title: String, message: String, provider: String? = null) =
        AlertRecord(
            id = id, type = type, severity = "Warning", title = title, message = message,
            createdAt = "2026-09-17T00:00:00Z", isRead = false, isResolved = false, relatedProvider = provider,
        )

    @Test
    fun `device CPU from the macOS generator and the Python helper`() {
        val a = record("cpu-spike-mac-1", "Usage Spike", "Device CPU usage is elevated", "helper sampled CPU usage at 91%.")
        assertEquals(AlertPresentation.Kind.DeviceCpu("91"), AlertPresentation.classify(a))
    }

    @Test
    fun `session CPU in all three producer wordings`() {
        val title = "api-gateway is consuming high CPU"
        assertEquals(
            AlertPresentation.Kind.SessionCpuSystem("api-gateway", "37", "10", "Claude"),
            AlertPresentation.classify(record("session-spike-s1", "Usage Spike", title,
                "Using ~37% of total system CPU (10 cores) for Claude.")),
        )
        assertEquals(
            AlertPresentation.Kind.SessionCpuProcess("api-gateway", "184.5", "Claude"),
            AlertPresentation.classify(record("session-spike-s1", "Usage Spike", title, "Process CPU is 184.5% for Claude.")),
        )
    }

    @Test
    fun `the desktop form keeps its project out of the provider`() {
        // Order matters: the Python pattern's greedy (.+) would read "Claude in acme" as the provider.
        val a = record("session-spike-s1", "Usage Spike", "api-gateway is consuming high CPU",
            "Process CPU is 184.5% for Claude in acme.")
        assertEquals(
            AlertPresentation.Kind.SessionCpuProcessInProject("api-gateway", "184.5", "Claude", "acme"),
            AlertPresentation.classify(a),
        )
    }

    @Test
    fun `long session`() {
        val a = record("session-long-s1", "Session Too Long", "api-gateway has been running for a long time",
            "Long-running local agent session detected by helper.")
        assertEquals(AlertPresentation.Kind.SessionLong("api-gateway"), AlertPresentation.classify(a))
    }

    @Test
    fun `quota with and without a reset, provider stored or recovered from the title`() {
        assertEquals(
            AlertPresentation.Kind.Quota("Claude", "Weekly", "85", "15", null),
            AlertPresentation.classify(record("quota-Claude-Weekly-80", "Quota Warning", "Claude Weekly at 85%",
                "Quota window 'Weekly' is 85% used (15% remaining).", provider = "Claude")),
        )
        assertEquals(
            AlertPresentation.Kind.Quota("Codex", "5h Window", "96", "4", "2026-09-16T14:00:00Z"),
            AlertPresentation.classify(record("quota-Codex-5h Window-95", "Quota Warning", "Codex 5h Window at 96%",
                "Quota window '5h Window' is 96% used (4% remaining) (resets 2026-09-16T14:00:00Z).")),
        )
    }

    @Test
    fun `desktop budgets`() {
        assertEquals(
            AlertPresentation.Kind.BudgetDaily("12.34", "12.34", "10.00"),
            AlertPresentation.classify(record("budget-daily-2026-09-16", "Daily Budget Exceeded",
                "Daily budget exceeded — \$12.34", "Today's spend of \$12.34 is above your daily budget of \$10.00.")),
        )
        assertEquals(
            AlertPresentation.Kind.BudgetWeekly("88.20", "88.20", "50.00"),
            AlertPresentation.classify(record("budget-weekly-2026-W38", "Weekly Budget Exceeded",
                "Weekly budget exceeded — \$88.20", "Last 7 days of spend totals \$88.20, above your weekly budget of \$50.00.")),
        )
    }

    @Test
    fun `anything unrecognized keeps its stored English`() {
        val misses = listOf(
            record("a1", "Quota Critical", "Claude quota almost gone", "You have used 96% of your weekly quota."),
            record("future-1", "Something New", "A kind from a newer client", "Written by a version this one has never seen."),
            // Right id and type, but a template this client does not know.
            record("cpu-spike-mac-1", "Usage Spike", "Device CPU usage is elevated", "helper measured CPU at 91 percent."),
            // Right template, wrong id prefix.
            record("x-1", "Usage Spike", "Device CPU usage is elevated", "helper sampled CPU usage at 91%."),
        )
        for (a in misses) assertNull(a.id, AlertPresentation.classify(a))
    }
}

/**
 * The Kotlin patterns must be the Swift patterns. Both apps render the same rows from
 * the same producers; if one side's template changes and the other's does not, that
 * platform silently falls back to English. Fails (never skips) if the Swift file moves.
 */
class AlertPresentationParityTest {
    @Test
    fun `kotlin patterns equal the swift patterns`() {
        val swift = File("../../CLI Pulse Bar/CLIPulseCore/Sources/CLIPulseCore/AlertPresentation.swift")
        assertTrue("Swift source not found at ${swift.absolutePath}", swift.isFile)
        val swiftPatterns = Regex("""#"(.*?)"#""").findAll(swift.readText()).map { it.groupValues[1] }.toSet()
        assertTrue("found only ${swiftPatterns.size} Swift patterns", swiftPatterns.size >= 9)
        assertEquals(swiftPatterns, AlertPresentation.PATTERNS.toSet())
    }
}
