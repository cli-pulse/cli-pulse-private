package com.clipulse.android.ui.common

import androidx.annotation.StringRes
import androidx.compose.runtime.Composable
import androidx.compose.ui.res.stringResource
import com.clipulse.android.R

/**
 * Display text for a quota tier name ("Weekly", "5h Window", "Credits").
 *
 * The stored name stays English: every platform uploads it, alerts use it as a
 * suppression key, and the Apple Watch finds the weekly window by matching "week" in
 * it. Only the rendering is translated, exactly as Apple's `L10n.quotaTier.localized`.
 *
 * Which names translate is decided once, with a reason each, in
 * `scripts/quota_tier_names.json`: generic words the apps composed translate; vendor
 * products, plans, models, coined units and currency codes ("Ark Plan", "Pro",
 * "Compute Points") pass through so the row still matches the vendor's billing page.
 * `scripts/check_quota_tier_names.py` fails if a TRANSLATE name is missing here or
 * from any of the six string files, and `QuotaTierDisplayTest` reads the manifest.
 */
object QuotaTierDisplay {
    // Keys are lowercase: producers disagree on capitalization ("Voice slots").
    private val LABELS = mapOf(
        "4-hour" to R.string.quota_tier_hours_4,
        "5-hour" to R.string.quota_tier_hours_5,
        "5h rate limit" to R.string.quota_tier_rate_limit_5h,
        "5h window" to R.string.quota_tier_window_5h,
        "ai credits" to R.string.quota_tier_ai_credits,
        "billing cycle" to R.string.quota_tier_billing_cycle,
        "bonus" to R.string.quota_tier_bonus,
        "bonus credits" to R.string.quota_tier_bonus_credits,
        "cash" to R.string.quota_tier_cash_balance,
        "characters" to R.string.quota_tier_characters,
        "credits" to R.string.quota_tier_credits,
        "daily" to R.string.quota_tier_daily,
        "default" to R.string.quota_tier_default,
        "extra usage" to R.string.quota_tier_extra_usage,
        "key limit" to R.string.quota_tier_key_limit,
        "monthly" to R.string.quota_tier_monthly,
        "on-demand" to R.string.quota_tier_on_demand,
        "open source" to R.string.quota_tier_open_source,
        "opus (weekly)" to R.string.quota_tier_opus_weekly,
        "opus only" to R.string.quota_tier_opus_only,
        "other" to R.string.quota_tier_other_models,
        "overall" to R.string.quota_tier_overall,
        "plan" to R.string.quota_tier_plan_included,
        "professional voices" to R.string.quota_tier_professional_voices,
        "purchased" to R.string.quota_tier_purchased,
        "quota" to R.string.quota_tier_quota_fallback,
        "recurring" to R.string.quota_tier_recurring,
        "refresh" to R.string.quota_tier_refresh_credits,
        "requests" to R.string.quota_tier_requests,
        "rolling" to R.string.quota_tier_rolling_window,
        "session" to R.string.quota_tier_session,
        "sonnet (weekly)" to R.string.quota_tier_sonnet_weekly,
        "sonnet only" to R.string.quota_tier_sonnet_only,
        "tariff credits" to R.string.quota_tier_tariff_credits,
        "time" to R.string.quota_tier_time_limit,
        "tokens" to R.string.quota_tier_tokens,
        "voice slots" to R.string.quota_tier_voice_slots,
        "voucher" to R.string.quota_tier_voucher_balance,
        "weekly" to R.string.quota_tier_weekly,
        "window" to R.string.quota_tier_window_fallback,
    )

    /** The string resource for a tier name, or null to show the name as it arrived. */
    @StringRes
    fun label(name: String): Int? = LABELS[name.lowercase()]
}

@Composable
fun quotaTierLabel(name: String): String = QuotaTierDisplay.label(name)?.let { stringResource(it) } ?: name
