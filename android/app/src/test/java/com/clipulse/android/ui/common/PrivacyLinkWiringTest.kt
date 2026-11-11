package com.clipulse.android.ui.common

import java.io.File
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * WIRING check only. It reads the Kotlin sources as text, so a comment, an unreachable call or a
 * misplaced composable could still satisfy it. It proves nothing about visibility or centring;
 * those are covered by the manual emulator gate in the PR description.
 */
class PrivacyLinkWiringTest {
    /** Gradle runs unit tests from `android/app`; an IDE may run them from the repo root. */
    private fun repoFile(relative: String): File {
        val candidates = listOf(File(relative), File("android/app/$relative"))
        return candidates.firstOrNull { it.isFile }
            ?: throw AssertionError("source not found: $relative (tried ${candidates.map { it.absolutePath }})")
    }

    private val base = "src/main/java/com/clipulse/android/ui"

    private fun settings() = repoFile("$base/settings/SettingsScreen.kt").readText()
    private fun login() = repoFile("$base/login/LoginScreen.kt").readText()

    @Test
    fun `settings screen shows the privacy policy link`() {
        assertTrue("SettingsScreen must call PrivacyPolicyLink(", settings().contains("PrivacyPolicyLink("))
    }

    @Test
    fun `login screen shows the privacy policy link`() {
        assertTrue("LoginScreen must call PrivacyPolicyLink(", login().contains("PrivacyPolicyLink("))
    }

    @Test
    fun `login screen scrolls`() {
        assertTrue("LoginScreen must use verticalScroll(", login().contains("verticalScroll("))
    }

    @Test
    fun `login loading branch shows the link before returning`() {
        val loading = Regex(
            """if \(state\.isLoading\) \{(.*?)return@Column""",
            RegexOption.DOT_MATCHES_ALL,
        ).find(login())
        assertTrue("loading branch not found in LoginScreen", loading != null)
        assertTrue(
            "the loading branch must call PrivacyPolicyLink( before return@Column",
            loading!!.groupValues[1].contains("PrivacyPolicyLink("),
        )
    }

    @Test
    fun `login link is also the last call after the form chain`() {
        val src = login()
        val last = src.lastIndexOf("PrivacyPolicyLink()")
        val demo = src.lastIndexOf("viewModel.enterDemoMode()")
        assertTrue("the trailing PrivacyPolicyLink() must come after the Try Demo button", last > demo && demo > 0)
    }
}
