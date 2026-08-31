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
            // The plan card and the Restore button are both gone.
            //
            // The card sourced `tier` from BillingManager, i.e. from Google
            // Play — which can never report anything but "free" here: the Play
            // account has no Google Payments merchant account, so the SKUs were
            // never creatable. A genuine Pro subscriber (who bought on Apple)
            // saw "Current Plan: Free", one tap from the Settings screen that
            // reads the TRUTH via `serverTier()` → `get_user_tier`, which
            // returns 'pro' from an active `subscriptions` row.
            //
            // Restore called `queryPurchasesAsync` against Play for
            // `com.clipulse.android`, so it could never see an Apple
            // entitlement either — pressing it re-wrote the state already on
            // screen. Its old comment ("anyone who already paid must still be
            // able to recover their entitlement") was true as an intention and
            // false as a description of what the button did.
            Card(modifier = Modifier.fillMaxWidth()) {
                Column(modifier = Modifier.padding(16.dp)) {
                    Text(
                        stringResource(R.string.subscription_unavailable_android),
                        style = MaterialTheme.typography.bodyMedium,
                    )
                }
            }

        }
    }
}
