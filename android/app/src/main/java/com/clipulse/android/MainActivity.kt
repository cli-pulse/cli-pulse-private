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
     * it. Retained across a configuration change: a rotation while the browser was open, or
     * while the claim was out, neither loses the callback nor delivers it twice. Not across a
     * process death (see its class comment).
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
        // Only an intent this Activity was started with just now (shouldHandleLaunchIntent): not
        // the one a recreated Activity carries (a rotation, or a restore after a process
        // death: savedInstanceState != null), which is its last intent, kept by setIntent;
        // and not the original intent Android hands back when the app is relaunched from
        // Recents (FLAG_ACTIVITY_LAUNCHED_FROM_HISTORY, as Android 8 to 11 can do).
        // Either can be an OLD OAuth deep link. After a rotation, what it routed is still
        // held by [oauthCallbacks]; after a process death it is gone, and replaying the link
        // cannot bring it back (its flow was claimed). The claim itself only takes a pending
        // flow whose state matches, so a stale link no longer costs a newer flow its record;
        // not replaying it is the second line. A deep link that arrives while the Activity
        // exists, including one that brings a recreated Activity back, comes through
        // onNewIntent.
        val fromHistory = ((intent?.flags ?: 0) and Intent.FLAG_ACTIVITY_LAUNCHED_FROM_HISTORY) != 0
        if (shouldHandleLaunchIntent(isRecreation = savedInstanceState != null, fromHistory = fromHistory)) {
            handleOAuthDeepLink(intent)
        }
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
        // IO thread, in its own scope, so a rotation cannot cancel it half-way), and only by
        // the callback whose state it holds. A second callback for the same flow (a second
        // tap on the browser's return) finds nothing; an older flow's callback leaves the
        // record alone; and a sign-in or sign-out since the flow started has dropped it.
        oauthCallbacks.receive(OAuthCallbackParser.parse(data))
    }
}
