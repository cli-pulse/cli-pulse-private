package com.clipulse.android.ui.navigation

import androidx.annotation.StringRes
import androidx.compose.ui.res.stringResource
import com.clipulse.android.R
import androidx.compose.foundation.layout.padding
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.List
import androidx.compose.material.icons.filled.*
import androidx.compose.material3.*
import androidx.compose.material3.adaptive.navigationsuite.NavigationSuiteScaffold
import androidx.compose.material3.adaptive.navigationsuite.NavigationSuiteType
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.navigation.NavDestination.Companion.hierarchy
import androidx.navigation.NavGraph.Companion.findStartDestination
import androidx.navigation.NavType
import androidx.navigation.compose.NavHost
import androidx.navigation.compose.composable
import androidx.navigation.compose.currentBackStackEntryAsState
import androidx.navigation.compose.rememberNavController
import androidx.navigation.navArgument
import com.clipulse.android.MainActivity
import com.clipulse.android.data.remote.OAuthDeepLinkCallback
import com.clipulse.android.data.remote.OAuthDeepLinkNotice
import com.clipulse.android.ui.alerts.AlertsScreen
import com.clipulse.android.ui.login.LoginScreen
import com.clipulse.android.ui.overview.OverviewScreen
import com.clipulse.android.ui.providers.ProviderDetailRoute
import com.clipulse.android.ui.providers.ProvidersScreen
import com.clipulse.android.ui.sessions.SessionsScreen
import com.clipulse.android.ui.devices.DevicesScreen
import com.clipulse.android.ui.settings.SettingsScreen
import com.clipulse.android.ui.settings.SubscriptionScreen
import com.clipulse.android.ui.usage.CostAnalysisScreen

val LocalSnackbarHostState = compositionLocalOf<SnackbarHostState> {
    error("No SnackbarHostState provided")
}

/// Bottom-nav destinations.
///
/// `labelRes`, not a hardcoded String: the labels used to be English literals
/// here, so the navigation bar rendered in English for every locale while the
/// translated `tab_*` strings sat in all six `values-*` files, referenced by
/// nothing. That is why an unused-string scan flagged them — they were unused
/// because the bar never asked for them.
enum class Screen(
    val route: String,
    @StringRes val labelRes: Int,
    val icon: ImageVector,
) {
    Overview("overview", R.string.tab_overview, Icons.Default.Dashboard),
    Providers("providers", R.string.tab_providers, Icons.Default.Dns),
    Sessions("sessions", R.string.tab_sessions, Icons.AutoMirrored.Filled.List),
    Alerts("alerts", R.string.tab_alerts, Icons.Default.Notifications),
    Settings("settings", R.string.tab_settings, Icons.Default.Settings),
}

@Composable
fun AppNavigation(
    pendingCallback: OAuthDeepLinkCallback? = null,
    pendingNotice: OAuthDeepLinkNotice? = null,
) {
    val navController = rememberNavController()
    var isLoggedIn by remember { mutableStateOf(false) }

    // Only deliver a callback to the screen whose flow-kind matches. A login callback
    // received while we're on the authenticated stack, or vice versa, is ignored — the
    // MainActivity has already cleared the pending-flow record.
    val loginCallback = pendingCallback?.takeIf { it.kind == "login" }
    val linkCallback = pendingCallback?.takeIf { it.kind == "link" }
    val loginNotice = pendingNotice?.takeIf { it.kind == "login" }
    val linkNotice = pendingNotice?.takeIf { it.kind == "link" }

    if (!isLoggedIn) {
        LoginScreen(
            loginCallback = loginCallback,
            loginNotice = loginNotice,
            onLoggedIn = { isLoggedIn = true },
        )
        return
    }

    val snackbarHostState = remember { SnackbarHostState() }
    val tabs = Screen.entries
    val navBackStackEntry by navController.currentBackStackEntryAsState()
    val currentDestination = navBackStackEntry?.destination

    // The POST_NOTIFICATIONS pre-prompt was removed: Android cannot receive a
    // notification from this backend at all, so asking was a system permission
    // request that could never pay off.
    //
    //   * `app_push_tokens` is the ONLY table either push sender reads, and its
    //     platform column is `CHECK (platform IN ('ios','macos'))` — verified
    //     against production 2026-08-31, so an Android row cannot exist.
    //   * `send-approval-push` rejects anything else explicitly
    //     (`unknown_platform`), and there is no FCM sender anywhere in backend/.
    //   * Android's token goes to `devices.push_token`, a column no backend
    //     code reads.
    //
    // The receiver (`fcm/PushService.kt`) and the manifest declaration are left
    // in place: if a sender ever ships, restoring the prompt is one line here.
    // Do not restore it before then.

    // If a link-flow OAuth deep link arrived while the user wasn't on the Settings
    // tab, auto-navigate there so SettingsScreen's LaunchedEffects can consume the
    // callback / surface the notice. Login callbacks are intentionally not routed
    // here — pre-auth there's only one screen and LoginScreen already consumes them.
    LaunchedEffect(linkCallback, linkNotice) {
        if (linkCallback == null && linkNotice == null) return@LaunchedEffect
        if (currentDestination?.route == Screen.Settings.route) return@LaunchedEffect
        navController.navigate(Screen.Settings.route) {
            popUpTo(navController.graph.findStartDestination().id) { saveState = true }
            launchSingleTop = true
            restoreState = true
        }
    }

    // v1.21 E2: NavigationSuiteScaffold auto-renders NavigationBar (compact
    // width / phones) or NavigationRail / PermanentDrawer (expanded width /
    // tablets, foldables) based on the active window size class. Replaces
    // the previous Scaffold+NavigationBar pair, which collapsed the
    // navigation UX on wide displays.
    //
    // Detail routes still hide the navigation surface to preserve the
    // pre-E2 phone UX where deeper screens gain the full vertical extent.
    // On tablet/foldable widths the rail stays — that's the whole point of
    // the rail pattern: persistent top-level switching.
    val isTopLevel = tabs.any { currentDestination?.route == it.route }
    NavigationSuiteScaffold(
        layoutType = if (isTopLevel) {
            androidx.compose.material3.adaptive.navigationsuite.NavigationSuiteScaffoldDefaults
                .calculateFromAdaptiveInfo(
                    androidx.compose.material3.adaptive.currentWindowAdaptiveInfo()
                )
        } else {
            NavigationSuiteType.None
        },
        navigationSuiteItems = {
            tabs.forEach { screen ->
                item(
                    icon = {
                        Icon(screen.icon, contentDescription = stringResource(screen.labelRes))
                    },
                    label = { Text(stringResource(screen.labelRes)) },
                    selected = currentDestination?.hierarchy?.any { it.route == screen.route } == true,
                    onClick = {
                        navController.navigate(screen.route) {
                            popUpTo(navController.graph.findStartDestination().id) {
                                saveState = true
                            }
                            launchSingleTop = true
                            restoreState = true
                        }
                    },
                )
            }
        },
    ) {
        Scaffold(
            snackbarHost = { SnackbarHost(snackbarHostState) },
        ) { innerPadding ->
        CompositionLocalProvider(LocalSnackbarHostState provides snackbarHostState) {
        NavHost(
            navController = navController,
            startDestination = Screen.Overview.route,
            modifier = Modifier.padding(innerPadding),
        ) {
            composable(Screen.Overview.route) {
                OverviewScreen(
                    onCostAnalysis = { navController.navigate("cost_analysis") },
                )
            }
            composable(Screen.Providers.route) {
                ProvidersScreen(
                    onProviderClick = { providerName ->
                        navController.navigate("provider_detail/$providerName")
                    },
                )
            }
            composable(
                route = "provider_detail/{providerName}",
                arguments = listOf(navArgument("providerName") { type = NavType.StringType }),
            ) { backStackEntry ->
                val providerName = backStackEntry.arguments?.getString("providerName") ?: ""
                ProviderDetailRoute(
                    providerName = providerName,
                    onBack = { navController.popBackStack() },
                )
            }
            composable(Screen.Sessions.route) { SessionsScreen() }
            composable(Screen.Alerts.route) { AlertsScreen() }
            composable(Screen.Settings.route) {
                SettingsScreen(
                    linkCallback = linkCallback,
                    linkNotice = linkNotice,
                    onSignOut = { isLoggedIn = false },
                    onManageSubscription = { navController.navigate("subscription") },
                    onViewDevices = { navController.navigate("devices") },
                )
            }
            composable("subscription") {
                SubscriptionScreen(onBack = { navController.popBackStack() })
            }
            composable("devices") {
                DevicesScreen()
            }
            composable("cost_analysis") {
                CostAnalysisScreen(onBack = { navController.popBackStack() })
            }
        }
        }
        }
    }
}
