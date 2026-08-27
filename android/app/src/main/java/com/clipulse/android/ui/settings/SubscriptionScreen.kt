package com.clipulse.android.ui.settings

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.hilt.navigation.compose.hiltViewModel
import com.clipulse.android.R

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun SubscriptionScreen(
    viewModel: SubscriptionViewModel = hiltViewModel(),
    onBack: () -> Unit,
) {
    val state by viewModel.state.collectAsState()

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text(stringResource(R.string.subscription_title)) },
                navigationIcon = {
                    IconButton(onClick = onBack) {
                        Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = stringResource(R.string.back))
                    }
                },
            )
        },
    ) { innerPadding ->
        Column(
            modifier = Modifier
                .fillMaxSize()
                .padding(innerPadding)
                .verticalScroll(rememberScrollState())
                .padding(16.dp),
        ) {
            // Current tier
            Card(
                modifier = Modifier.fillMaxWidth(),
                colors = CardDefaults.cardColors(
                    containerColor = when (state.tier) {
                        "team" -> MaterialTheme.colorScheme.primaryContainer
                        "pro" -> MaterialTheme.colorScheme.secondaryContainer
                        else -> MaterialTheme.colorScheme.surfaceVariant
                    },
                ),
            ) {
                Column(modifier = Modifier.padding(16.dp)) {
                    Text(
                        stringResource(R.string.subscription_current_plan, state.tier.replaceFirstChar { it.uppercase() }),
                        style = MaterialTheme.typography.titleLarge,
                        fontWeight = FontWeight.Bold,
                    )
                    if (state.isPending) {
                        Spacer(Modifier.height(8.dp))
                        Text(
                            stringResource(R.string.subscription_processing),
                            style = MaterialTheme.typography.bodyMedium,
                            color = MaterialTheme.colorScheme.tertiary,
                        )
                    }
                }
            }

            Spacer(Modifier.height(16.dp))

            // Feature comparison
            Card(modifier = Modifier.fillMaxWidth()) {
                Column(modifier = Modifier.padding(16.dp)) {
                    Text(stringResource(R.string.subscription_plan_features), style = MaterialTheme.typography.titleMedium)
                    Spacer(Modifier.height(12.dp))
                    // v1.51 — this table used to claim three per-tier limits.
                    // Two were fiction and one disagreed with the Apple client:
                    //
                    //   Devices "1 / 5 / Unlimited" — nothing consults tier when
                    //     pairing; every tier caps at a flat 20
                    //     (migrate_v0.36_desktop_otp.sql:66). It also said the
                    //     free tier gets ONE device while the Apple paywall said
                    //     two, so whichever a user read, the other lied.
                    //   Data Retention "7 / 90 / 365" — the nightly cleanup is
                    //     tier-blind and reads user_settings.data_retention_days,
                    //     which this very app lets the user edit by hand
                    //     (SettingsScreen.kt:226).
                    //
                    // Providers stays because it is really enforced — though only
                    // by the Apple client; Android does not gate on tier at all.
                    // v1.52: the Team column is gone with the tier itself.
                    FeatureRow(stringResource(R.string.subscription_providers), "3", stringResource(R.string.subscription_unlimited))
                }
            }

            Spacer(Modifier.height(16.dp))

            // v1.52 — the purchase flow is removed from Android.
            //
            // Google Play Billing here was fully wired and fully real: a live
            // BillingClient, four real subscription SKUs, a real purchase flow,
            // and real server-side receipt validation writing an active
            // `subscriptions` row. What was missing is the other half — NO
            // Kotlin code reads the resulting entitlement. `SubscriptionState
            // .isActive` is written and never read; not one code path on
            // Android changes behaviour based on tier.
            //
            // So Play would charge the card and the app would do nothing
            // differently. That is the one item in this codebase with actual
            // refund exposure, and both external reviewers independently said
            // the fix is to stop taking the money rather than to build Android
            // tier gates for a tier nobody has validated.
            //
            // Restore stays below on purpose: anyone who already paid must
            // still be able to recover their entitlement.
            Card(modifier = Modifier.fillMaxWidth()) {
                Column(modifier = Modifier.padding(16.dp)) {
                    Text(
                        stringResource(R.string.subscription_unavailable_android),
                        style = MaterialTheme.typography.bodyMedium,
                    )
                }
            }

            Spacer(Modifier.height(16.dp))

            // Restore
            OutlinedButton(
                onClick = { viewModel.restore() },
                modifier = Modifier.fillMaxWidth(),
            ) {
                Icon(Icons.Default.Refresh, contentDescription = null)
                Spacer(Modifier.width(8.dp))
                Text(stringResource(R.string.subscription_restore))
            }
        }
    }
}

@Composable
private fun FeatureRow(label: String, free: String, pro: String) {
    Row(
        modifier = Modifier.fillMaxWidth().padding(vertical = 4.dp),
        horizontalArrangement = Arrangement.SpaceBetween,
    ) {
        Text(label, modifier = Modifier.weight(1f), style = MaterialTheme.typography.bodySmall)
        Text(free, modifier = Modifier.weight(1f), style = MaterialTheme.typography.bodySmall)
        Text(pro, modifier = Modifier.weight(1f), style = MaterialTheme.typography.bodySmall, fontWeight = FontWeight.Medium)
    }
}

