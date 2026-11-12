package com.clipulse.android.ui.navigation

import com.clipulse.android.repoFile
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * WIRING check, reading the sources as text: the gate is the only thing that leaves the tabs.
 * If Settings (or AppNavigation) also switched screens on a sign-out tap, the tap and the
 * session change it causes would both move the epoch. SessionGateViewModelTest covers the
 * gate's own transitions; this covers that nothing else makes one.
 */
class SessionNavigationWiringTest {
    private val base = "src/main/java/com/clipulse/android/ui"

    private fun source(path: String) = repoFile("$base/$path").readText()

    @Test
    fun `settings only ends the session and never navigates`() {
        val settings = source("settings/SettingsScreen.kt")
        assertFalse("SettingsScreen must not take a sign-out callback", settings.contains("onSignOut"))
        assertFalse("SettingsScreen must not navigate on deleteSuccess", settings.contains("deleteSuccess"))
    }

    @Test
    fun `app navigation renders the gate and moves no epoch of its own`() {
        val nav = source("navigation/AppNavigation.kt")
        assertTrue(nav.contains("SessionGateViewModel"))
        assertFalse(nav.contains("onSignOut"))
        assertFalse("only the gate ends a session's view models", nav.contains("endSession("))
        assertFalse("AppNavigation must not keep an epoch of its own", Regex("""[eE]poch\s*(\+\+|\+=|--|-=)""").containsMatchIn(nav))
        assertFalse(nav.contains("mutableIntStateOf"))
    }

    @Test
    fun `only the gate ends the tabs' view models`() {
        val callers = repoFile(base).walkTopDown()
            .filter { it.isFile && it.extension == "kt" }
            .filter { it.readText().contains("endSession(") }
            .map { it.name }
            .toSet()
        assertTrue("callers: $callers", callers == setOf("SessionGateViewModel.kt", "SessionViewModelStores.kt"))
    }

    @Test
    fun `the sign-in screen never restores a session itself`() {
        val login = source("login/LoginScreen.kt") + source("login/LoginViewModel.kt")
        assertFalse(login.contains("tryRestoreSession"))
        assertFalse(login.contains(".me("))
    }

    @Test
    fun `a sign-in callback that arrives while the tabs show is consumed and dropped`() {
        val nav = source("navigation/AppNavigation.kt")
        val tabsBranch = nav.substringAfter("if (gateState.screen != GateScreen.Tabs) {").substringAfter("return\n")
        assertTrue(tabsBranch.contains("consumePendingCallback()"))
        assertTrue(tabsBranch.contains("consumePendingNotice()"))
    }

    @Test
    fun `only the coordinator starts, ends or replaces a session`() {
        val transition = Regex("""tokenStore\s*\.\s*(installSession|enterDemoMode|endIfCurrent|endCurrent|clearPendingIfEquals)\s*\(""")
        val offenders = repoFile("src/main/java/com/clipulse/android").walkTopDown()
            .filter { it.isFile && it.extension == "kt" && it.name != "SessionLifecycle.kt" }
            .filter { transition.containsMatchIn(it.readText()) }
            .map { it.name }
            .toList()
        assertTrue("session transitions outside SessionLifecycle: $offenders", offenders.isEmpty())
    }
}
