package com.clipulse.android

import android.content.Intent
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.viewModels
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import com.clipulse.android.data.remote.OAuthCallbackParser
import com.clipulse.android.data.remote.SupabaseConfig
import com.clipulse.android.ui.diagnostics.ConfigurationErrorScreen
import com.clipulse.android.ui.navigation.AppNavigation
import com.clipulse.android.ui.navigation.OAuthCallbackViewModel
import com.clipulse.android.ui.theme.CLIPulseTheme
import dagger.hilt.android.AndroidEntryPoint

@AndroidEntryPoint
class MainActivity : ComponentActivity() {
    /**
     * Claims and holds an OAuth callback (or notice) until the screen of its kind consumes
     * it. Retained across a recreation: a rotation while the browser was open, or while the
     * claim was out, neither loses the callback nor delivers it twice.
     */
    private val oauthCallbacks: OAuthCallbackViewModel by viewModels()

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // Mis-configured release builds (missing SUPABASE_URL or SUPABASE_ANON_KEY)
        // would otherwise loop on 401s in the background, leaving the user staring
        // at a blank dashboard. Render a blocking diagnostics screen instead and
        // skip OAuth/sync wiring entirely.
        if (!SupabaseConfig.isConfigured) {
            enableEdgeToEdge()
            setContent {
                CLIPulseTheme {
                    ConfigurationErrorScreen(missingFieldsSummary = SupabaseConfig.missingFieldsSummary)
                }
            }
            return
        }
        // Only on a first creation. A recreated Activity (a rotation, or a restore after a
        // process death: savedInstanceState != null) still carries the intent it was created
        // with, which can be an OLD OAuth deep link. That link's flow was claimed when it
        // first arrived, and whatever it routed is still held by [oauthCallbacks], which
        // outlives the recreation, so replaying it has nothing to add. Worse, if a newer
        // sign-in or link has started since, the replay would claim THAT flow's pending
        // record against the old link's state: a spurious state mismatch, and the real
        // callback would then find nothing to complete. A deep link that arrives while the
        // Activity exists, including one that brings a recreated Activity back, comes
        // through onNewIntent.
        if (savedInstanceState == null) handleOAuthDeepLink(intent)
        enableEdgeToEdge()
        setContent {
            val pendingCallback by oauthCallbacks.pendingCallback.collectAsState()
            val pendingNotice by oauthCallbacks.pendingNotice.collectAsState()
            CLIPulseTheme {
                AppNavigation(
                    pendingCallback = pendingCallback,
                    pendingNotice = pendingNotice,
                )
            }
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        // Keeps getIntent() current. A recreation does not hand it over again (see
        // onCreate): what this pass routes is held by [oauthCallbacks] across a recreation.
        setIntent(intent)
        // Don't process deep links when config is missing — there's no client to
        // exchange against and the diagnostics screen is the only thing rendered.
        if (!SupabaseConfig.isConfigured) return
        handleOAuthDeepLink(intent)
    }

    /** Called by the screen after handling a successful callback. */
    fun consumePendingCallback() {
        oauthCallbacks.consumeCallback()
    }

    /** Called by the screen after surfacing a notice to the user. */
    fun consumePendingNotice() {
        oauthCallbacks.consumeNotice()
    }

    private fun handleOAuthDeepLink(intent: Intent?) {
        val data = intent?.data ?: return
        // Accept both App Links (https://clipulse.app/auth/callback) and the
        // fallback custom-scheme (clipulse://auth/callback).
        val isHttps = data.scheme == "https" && data.host == "clipulse.app" && data.path == "/auth/callback"
        val isCustom = data.scheme == "clipulse" && data.host == "auth" && data.path == "/callback"
        if (!isHttps && !isCustom) return

        // Claimed, not just read: the record is removed once, by the retained owner (on an
        // IO thread, in its own scope, so a recreation cannot cancel it half-way). A second
        // callback for the same flow (a second tap on the browser's return) finds nothing,
        // and a sign-in or sign-out since the flow started has already dropped it.
        oauthCallbacks.receive(OAuthCallbackParser.parse(data))
    }
}
