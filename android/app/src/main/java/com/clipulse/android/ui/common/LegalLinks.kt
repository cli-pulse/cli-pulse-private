package com.clipulse.android.ui.common

import android.app.Activity
import android.content.ActivityNotFoundException
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.widget.Toast
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import com.clipulse.android.R

/**
 * Canonical privacy-policy address. Same literal as the Apple apps. Never the legacy
 * per-user Pages host: `scripts/check_legal_urls.sh` rejects it in Kotlin and XML.
 */
const val PRIVACY_POLICY_URL = "https://cli-pulse.github.io/cli-pulse/privacy.html"

/** Opens the policy in the system browser. No WebView: the page is public. */
fun openPrivacyPolicy(context: Context) {
    val intent = Intent(Intent.ACTION_VIEW, Uri.parse(PRIVACY_POLICY_URL))
    if (context !is Activity) intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
    try {
        context.startActivity(intent)
    } catch (_: ActivityNotFoundException) {
        Toast.makeText(context, R.string.privacy_policy_unavailable, Toast.LENGTH_SHORT).show()
    }
}

@Composable
fun PrivacyPolicyLink(modifier: Modifier = Modifier) {
    val context = LocalContext.current
    TextButton(onClick = { openPrivacyPolicy(context) }, modifier = modifier) {
        Text(stringResource(R.string.privacy_policy))
    }
}
