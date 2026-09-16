package com.clipulse.android.ui.alerts

import androidx.compose.runtime.Composable
import androidx.compose.ui.res.stringResource
import com.clipulse.android.R
import com.clipulse.android.data.model.AlertRecord
import com.clipulse.android.ui.common.quotaTierLabel

/**
 * Localized title and message for an alert row, recovered from the English its
 * producer wrote. A port of Apple's `AlertPresentation.swift`; read that file's
 * header for the full reasoning. In short:
 *
 * - `public.alerts` has no kind or parameters column, and every device receives the
 *   producing device's `title`/`message` bytes. So the stored row stays English and
 *   only the rendering is translated.
 * - Three producers write these rows with different wording: the macOS
 *   `AlertGenerator`, the Python helper and the Tauri desktop app. Android writes
 *   none, but shows all of them.
 * - Anything unrecognized renders the stored English unchanged.
 *
 * The server's `evaluate_budget_alerts` RPC is NOT a producer: the migrations still
 * carry its old "Budget exceeded: <project>" / "Cost Spike" templates, but the
 * production function body is a stub that inserts nothing (checked with
 * pg_get_functiondef, 2026-09-17).
 *
 * The regular expressions are copied verbatim from the Swift file, and
 * `AlertPresentationParityTest` fails if the two sets differ, so a template change
 * on one platform cannot silently leave the other rendering English.
 */
object AlertPresentation {

    sealed class Kind {
        data class DeviceCpu(val percent: String) : Kind()
        data class SessionCpuSystem(val session: String, val percent: String, val cores: String, val provider: String) : Kind()
        data class SessionCpuProcessInProject(val session: String, val percent: String, val provider: String, val project: String) : Kind()
        data class SessionCpuProcess(val session: String, val percent: String, val provider: String) : Kind()
        data class SessionLong(val session: String) : Kind()
        data class Quota(val provider: String, val tier: String, val used: String, val remaining: String, val reset: String?) : Kind()
        data class BudgetDaily(val amount: String, val spend: String, val budget: String) : Kind()
        data class BudgetWeekly(val amount: String, val spend: String, val budget: String) : Kind()
    }

    internal const val DEVICE_CPU = """^helper sampled CPU usage at (\d+(?:\.\d+)?)%\.$"""
    internal const val SESSION_CPU_SYSTEM = """^Using ~(\d+)% of total system CPU \((\d+) cores\) for (.+)\.$"""
    internal const val SESSION_CPU_PROCESS_IN_PROJECT = """^Process CPU is (\d+(?:\.\d+)?)% for (.+) in (.+)\.$"""
    internal const val SESSION_CPU_PROCESS = """^Process CPU is (\d+(?:\.\d+)?)% for (.+)\.$"""
    internal const val QUOTA = """^Quota window '(.+)' is (\d+)% used \((\d+)% remaining\)(?: \(resets (.+)\))?\.$"""
    internal const val BUDGET_DAILY_TITLE = """^Daily budget exceeded — \$(.+)$"""
    internal const val BUDGET_DAILY_MESSAGE = """^Today's spend of \$(.+) is above your daily budget of \$(.+)\.$"""
    internal const val BUDGET_WEEKLY_TITLE = """^Weekly budget exceeded — \$(.+)$"""
    internal const val BUDGET_WEEKLY_MESSAGE = """^Last 7 days of spend totals \$(.+), above your weekly budget of \$(.+)\.$"""

    internal val PATTERNS = listOf(
        DEVICE_CPU, SESSION_CPU_SYSTEM, SESSION_CPU_PROCESS_IN_PROJECT, SESSION_CPU_PROCESS, QUOTA,
        BUDGET_DAILY_TITLE, BUDGET_DAILY_MESSAGE, BUDGET_WEEKLY_TITLE, BUDGET_WEEKLY_MESSAGE,
    )

    /** What kind of alert this is and its parameters, or null to show the stored English. */
    fun classify(a: AlertRecord): Kind? =
        deviceCpu(a) ?: sessionCpu(a) ?: sessionLong(a) ?: quota(a) ?: budget(a)

    private fun deviceCpu(a: AlertRecord): Kind? {
        if (a.type != "Usage Spike" || !a.id.startsWith("cpu-spike-") || a.title != "Device CPU usage is elevated") return null
        val m = capture(a.message, DEVICE_CPU) ?: return null
        return Kind.DeviceCpu(m[0])
    }

    private fun sessionCpu(a: AlertRecord): Kind? {
        if (a.type != "Usage Spike" || !a.id.startsWith("session-spike-")) return null
        val session = stripSuffix(a.title, " is consuming high CPU")
        capture(a.message, SESSION_CPU_SYSTEM)?.let { return Kind.SessionCpuSystem(session, it[0], it[1], it[2]) }
        // Tauri desktop form, tried before the Python helper's: that pattern's greedy
        // `(.+)` would otherwise swallow " in <project>" into the provider.
        capture(a.message, SESSION_CPU_PROCESS_IN_PROJECT)?.let {
            return Kind.SessionCpuProcessInProject(session, it[0], it[1], it[2])
        }
        capture(a.message, SESSION_CPU_PROCESS)?.let { return Kind.SessionCpuProcess(session, it[0], it[1]) }
        return null
    }

    private fun sessionLong(a: AlertRecord): Kind? {
        if (a.type != "Session Too Long" || !a.id.startsWith("session-long-") ||
            a.message != "Long-running local agent session detected by helper."
        ) return null
        return Kind.SessionLong(stripSuffix(a.title, " has been running for a long time"))
    }

    private fun quota(a: AlertRecord): Kind? {
        if (a.type != "Quota Warning" || !a.id.startsWith("quota-")) return null
        val m = capture(a.message, QUOTA) ?: return null
        val tier = m[0]
        val used = m[1]
        // The title is "<provider> <tier> at <used>%": prefer the stored provider, else
        // remove that exact, anchored suffix.
        val provider = a.relatedProvider ?: stripSuffix(a.title, " $tier at $used%")
        return Kind.Quota(provider, tier, used, m[2], m.getOrNull(3))
    }

    private fun budget(a: AlertRecord): Kind? {
        if (a.type == "Daily Budget Exceeded" && a.id.startsWith("budget-daily-")) {
            val t = capture(a.title, BUDGET_DAILY_TITLE)
            val m = capture(a.message, BUDGET_DAILY_MESSAGE)
            if (t != null && m != null) return Kind.BudgetDaily(t[0], m[0], m[1])
        }
        if (a.type == "Weekly Budget Exceeded" && a.id.startsWith("budget-weekly-")) {
            val t = capture(a.title, BUDGET_WEEKLY_TITLE)
            val m = capture(a.message, BUDGET_WEEKLY_MESSAGE)
            if (t != null && m != null) return Kind.BudgetWeekly(t[0], m[0], m[1])
        }
        return null
    }

    /** Groups of an anchored match; a group that did not take part is dropped, as in Swift. */
    private fun capture(s: String, pattern: String): List<String>? =
        Regex(pattern).find(s)?.groups?.drop(1)?.mapNotNull { it?.value }

    private fun stripSuffix(s: String, suffix: String): String = if (s.endsWith(suffix)) s.dropLast(suffix.length) else s
}

@Composable
fun AlertRecord.displayTitle(kind: AlertPresentation.Kind?): String = when (kind) {
    null -> title
    is AlertPresentation.Kind.DeviceCpu -> stringResource(R.string.alert_kind_device_cpu_title)
    is AlertPresentation.Kind.SessionCpuSystem -> stringResource(R.string.alert_kind_session_cpu_title, kind.session)
    is AlertPresentation.Kind.SessionCpuProcessInProject -> stringResource(R.string.alert_kind_session_cpu_title, kind.session)
    is AlertPresentation.Kind.SessionCpuProcess -> stringResource(R.string.alert_kind_session_cpu_title, kind.session)
    is AlertPresentation.Kind.SessionLong -> stringResource(R.string.alert_kind_session_long_title, kind.session)
    is AlertPresentation.Kind.Quota ->
        stringResource(R.string.alert_kind_quota_title, kind.provider, quotaTierLabel(kind.tier), kind.used)
    is AlertPresentation.Kind.BudgetDaily -> stringResource(R.string.alert_kind_budget_daily_title, kind.amount)
    is AlertPresentation.Kind.BudgetWeekly -> stringResource(R.string.alert_kind_budget_weekly_title, kind.amount)
}

@Composable
fun AlertRecord.displayMessage(kind: AlertPresentation.Kind?): String = when (kind) {
    null -> message
    is AlertPresentation.Kind.DeviceCpu -> stringResource(R.string.alert_kind_device_cpu_message, kind.percent)
    is AlertPresentation.Kind.SessionCpuSystem ->
        stringResource(R.string.alert_kind_session_cpu_message_system, kind.percent, kind.cores, kind.provider)
    is AlertPresentation.Kind.SessionCpuProcessInProject ->
        stringResource(R.string.alert_kind_session_cpu_message_process_in_project, kind.percent, kind.provider, kind.project)
    is AlertPresentation.Kind.SessionCpuProcess ->
        stringResource(R.string.alert_kind_session_cpu_message_process, kind.percent, kind.provider)
    is AlertPresentation.Kind.SessionLong -> stringResource(R.string.alert_kind_session_long_message)
    is AlertPresentation.Kind.Quota -> if (kind.reset == null) {
        stringResource(R.string.alert_kind_quota_message, quotaTierLabel(kind.tier), kind.used, kind.remaining)
    } else {
        stringResource(R.string.alert_kind_quota_message_reset, quotaTierLabel(kind.tier), kind.used, kind.remaining, kind.reset)
    }
    is AlertPresentation.Kind.BudgetDaily -> stringResource(R.string.alert_kind_budget_daily_message, kind.spend, kind.budget)
    is AlertPresentation.Kind.BudgetWeekly -> stringResource(R.string.alert_kind_budget_weekly_message, kind.spend, kind.budget)
}
