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
        handleOAuthDeepLink(intent)
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
        // Persist the deep-link intent so a configuration change after onNewIntent
        // recreates with getIntent() == deep link and onCreate can replay it.
        // Replay is idempotent: the first pass claimed the pending flow record, so
        // the router returns Drop on the second pass, and what the first pass routed is
        // still held by [oauthCallbacks].
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
        // callback for the same flow (a replayed intent, a second tap on the browser's
        // return) finds nothing, and a sign-in or sign-out since the flow started has
        // already dropped it.
        oauthCallbacks.receive(OAuthCallbackParser.parse(data))
    }
}
