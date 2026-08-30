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

            // v1.52.1 — the Free-vs-Pro comparison table is gone.
            //
            // It rendered "Providers · 3 · Unlimited" directly above a card
            // reading "Nothing in this app is locked — every feature is
            // available to you as it is." Both were on screen at once and only
            // one of them could be true.
            //
            // The card is the true one. The 3-provider cap is enforced by the
            // Apple client alone (`AppState.swift`, `if currentEnabled >=
            // maxProviders`); no Kotlin code path on Android consults tier for
            // anything. The previous cleanup pass fixed the two rows it could
            // prove were fiction and kept this one because it is "really
            // enforced" — true of the product, false of this app. A limit that
            // this binary does not apply is not a limit this screen may claim.
            //
            // Nothing replaces it: with no purchase flow on Android there is no
            // decision for a comparison table to inform.

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
