package com.clipulse.android.ui.common

import androidx.annotation.StringRes
import androidx.compose.runtime.Composable
import androidx.compose.ui.res.stringResource
import com.clipulse.android.R

/**
 * Labels for values the server stores in English and every platform compares as data:
 * session and device statuses, alert severity, the account tier, webhook event types.
 *
 * Only the RENDERING is translated. The stored value keeps driving colors, filters, chip
 * selection and uploads, so a mapper never replaces it in state. Matching is
 * case-insensitive (the tier arrives as "pro", a severity as "Critical"), and an unknown
 * token returns null so the screen shows it as it arrived — a new server value reads as
 * itself, never as a wrong translation.
 */
object DataTokenDisplay {
    // The server's session statuses, not SessionStatus's: helper_rpc.sql also writes "Ended".
    private val SESSION_STATUS = mapOf(
        "running" to R.string.session_status_running,
        "idle" to R.string.session_status_idle,
        "failed" to R.string.session_status_failed,
        "syncing" to R.string.session_status_syncing,
        "ended" to R.string.session_status_ended,
    )
    private val DEVICE_STATUS = mapOf(
        "online" to R.string.device_status_online,
        "degraded" to R.string.device_status_degraded,
        "offline" to R.string.device_status_offline,
    )
    private val SEVERITY = mapOf(
        "critical" to R.string.alert_severity_critical,
        "warning" to R.string.alert_severity_warning,
        "info" to R.string.alert_severity_info,
    )
    private val ACCOUNT_TIER = mapOf(
        "free" to R.string.account_tier_free,
        "pro" to R.string.account_tier_pro,
        "team" to R.string.account_tier_team,
    )
    private val WEBHOOK_TYPE = mapOf(
        "cost_spike" to R.string.webhook_type_cost_spike,
        "quota_exceeded" to R.string.webhook_type_quota_exceeded,
        "session_long" to R.string.webhook_type_session_long,
        "device_offline" to R.string.webhook_type_device_offline,
    )

    @StringRes fun sessionStatus(raw: String?): Int? = lookup(SESSION_STATUS, raw)
    @StringRes fun deviceStatus(raw: String?): Int? = lookup(DEVICE_STATUS, raw)
    @StringRes fun severity(raw: String?): Int? = lookup(SEVERITY, raw)
    @StringRes fun accountTier(raw: String?): Int? = lookup(ACCOUNT_TIER, raw)
    @StringRes fun webhookType(raw: String?): Int? = lookup(WEBHOOK_TYPE, raw)

    // lowercase() is locale-invariant in Kotlin; toLowerCase() would turn "INFO" into
    // "ınfo" on a Turkish-locale JVM.
    private fun lookup(table: Map<String, Int>, raw: String?): Int? = raw?.trim()?.lowercase()?.let { table[it] }
}

/** The label for a stored token in the app's language, or the token itself when it is not one we know. */
@Composable
fun tokenLabel(raw: String, @StringRes label: Int?): String = label?.let { stringResource(it) } ?: raw
