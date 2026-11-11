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

    /** Null when the trailing link sits after the form chain's closing brace, else the reason. */
    private fun trailingLinkProblem(source: String): String? {
        val lines = source.lines()
        val chain = lines.indexOfFirst { it.trim() == "if (state.showOtpInput) {" }
        if (chain < 0) return "form chain not found in LoginScreen"
        val chainIndent = lines[chain].takeWhile { it == ' ' }.length
        val call = lines.indexOfLast { it.trim() == "PrivacyPolicyLink()" }
        if (call <= chain) return "trailing PrivacyPolicyLink() not found"
        if (lines[call].takeWhile { it == ' ' }.length != chainIndent) {
            return "the trailing link must be at the form chain's indentation, not nested in a branch"
        }
        val previous = lines.subList(chain + 1, call).lastOrNull { it.isNotBlank() }
        if (previous == null || previous.trim() != "}" || previous.takeWhile { it == ' ' }.length != chainIndent) {
            return "the line before the trailing link must close the whole if/else chain"
        }
        // Block structure, not just indentation: the braces between the chain start and the link balance.
        val between = lines.subList(chain, call).joinToString("\n")
        val depth = between.count { it == '{' } - between.count { it == '}' }
        if (depth != 0) return "braces between the form chain and the trailing link do not balance (depth $depth)"
        return null
    }

    @Test
    fun `login trailing link sits after the closing brace of the whole form chain`() {
        val problem = trailingLinkProblem(login())
        assertTrue(problem ?: "", problem == null)
    }

    @Test
    fun `a link moved inside the demo branch is rejected`() {
        val misplaced = """
            |            if (state.showOtpInput) {
            |                Text("otp")
            |            } else {
            |                TextButton(onClick = { viewModel.enterDemoMode() }) {
            |                    Text("demo")
            |                }
            |            PrivacyPolicyLink()
            |            }
        """.trimMargin()
        assertTrue("fixture should be rejected", trailingLinkProblem(misplaced) != null)
        val misplacedDeeper = """
            |            if (state.showOtpInput) {
            |                Text("otp")
            |            } else {
            |                TextButton(onClick = { viewModel.enterDemoMode() }) {
            |                    Text("demo")
            |                }
            |            }
            |            }
            |            PrivacyPolicyLink()
        """.trimMargin()
        assertTrue("unbalanced fixture should be rejected", trailingLinkProblem(misplacedDeeper) != null)
        val good = """
            |            if (state.showOtpInput) {
            |                Text("otp")
            |            } else {
            |                Text("demo")
            |            }
            |            PrivacyPolicyLink()
        """.trimMargin()
        assertTrue("good fixture should pass", trailingLinkProblem(good) == null)
    }

    @Test
    fun `login screen reserves window insets before scrolling`() {
        val src = login()
        val inset = src.indexOf("windowInsetsPadding(WindowInsets.safeDrawing)")
        val scroll = src.indexOf("verticalScroll(")
        assertTrue("LoginScreen must apply safeDrawing insets", inset >= 0)
        assertTrue("insets must be applied before verticalScroll", inset < scroll)
    }
}
