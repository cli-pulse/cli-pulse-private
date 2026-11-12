package com.clipulse.android

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * WIRING check, reading MainActivity's source as text (an Activity cannot be created in a JVM
 * unit test here): onCreate hands the Activity's intent to the OAuth callback owner only on a
 * first creation, and onNewIntent hands over every deep link that arrives. A recreated
 * Activity still carries the intent it was created with; replaying that OLD link would claim
 * a newer flow's pending record against the old state (OAuthCallbackViewModelTest shows the
 * cost), while what the old link routed is already held across the recreation.
 */
class MainActivityDeepLinkWiringTest {

    private val source = repoFile("src/main/java/com/clipulse/android/MainActivity.kt").readText()

    /** The body of [name] with line comments removed, so prose cannot satisfy or break a check. */
    private fun body(name: String, next: String): String =
        source.substringAfter("override fun $name(").substringBefore("override fun $next(")
            .lines().map { it.substringBefore("//") }.joinToString("\n")

    @Test
    fun `onCreate hands the deep link over only on a first creation`() {
        val onCreate = body("onCreate", "onNewIntent")
        assertEquals("one hand-over in onCreate", 1, Regex("""handleOAuthDeepLink\(""").findAll(onCreate).count())
        assertTrue(
            "onCreate's hand-over must be guarded by savedInstanceState == null:\n$onCreate",
            Regex("""if\s*\(\s*savedInstanceState\s*==\s*null\s*\)\s*handleOAuthDeepLink\(\s*intent\s*\)""").containsMatchIn(onCreate),
        )
    }

    @Test
    fun `onNewIntent hands over every deep link that arrives`() {
        val onNewIntent = body("onNewIntent", "onCreate").substringBefore("fun consumePendingCallback(")
        assertTrue(onNewIntent, onNewIntent.contains("handleOAuthDeepLink(intent)"))
        assertTrue("onNewIntent has no first-creation guard", !onNewIntent.contains("savedInstanceState"))
    }
}
