package com.clipulse.android

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * WIRING check, reading MainActivity's source as text (an Activity cannot be created in a JVM
 * unit test here): onCreate hands its intent over only as [shouldHandleLaunchIntent] decides
 * (LaunchIntentPolicyTest has the table), from the recreation and Recents signals; onNewIntent
 * hands over every deep link that arrives. Comments are removed first, so prose can neither
 * satisfy nor break a check.
 */
class MainActivityDeepLinkWiringTest {

    private val source = stripComments(repoFile("src/main/java/com/clipulse/android/MainActivity.kt").readText())

    /** The body of member [name], from its opening brace to the matching one. */
    private fun body(name: String): String {
        val start = source.indexOf("fun $name(")
        assertTrue("no fun $name in MainActivity", start >= 0)
        val open = source.indexOf('{', start)
        var depth = 0
        for (i in open until source.length) {
            when (source[i]) {
                '{' -> depth++
                '}' -> if (--depth == 0) return source.substring(open, i + 1)
            }
        }
        throw AssertionError("unbalanced braces in fun $name")
    }

    private fun squeeze(s: String) = s.replace(Regex("""\s+"""), " ")

    @Test
    fun `onCreate hands the deep link over only as the launch policy says`() {
        val onCreate = squeeze(body("onCreate"))
        assertEquals("one hand-over in onCreate", 1, Regex("""handleOAuthDeepLink\(""").findAll(onCreate).count())
        assertTrue(
            onCreate,
            Regex(
                """if \( ?shouldHandleLaunchIntent\( ?isRecreation = savedInstanceState != null, fromHistory = fromHistory ?\) ?\) ?\{ ?handleOAuthDeepLink\(intent\) ?\}""",
            ).containsMatchIn(onCreate),
        )
        assertTrue(onCreate, onCreate.contains("val fromHistory = ((intent?.flags ?: 0) and Intent.FLAG_ACTIVITY_LAUNCHED_FROM_HISTORY) != 0"))
    }

    @Test
    fun `onNewIntent hands over every deep link that arrives`() {
        val onNewIntent = squeeze(body("onNewIntent"))
        assertTrue(onNewIntent, onNewIntent.contains("handleOAuthDeepLink(intent)"))
        assertFalse("onNewIntent has no launch guard", onNewIntent.contains("shouldHandleLaunchIntent"))
    }

    @Test
    fun `comment stripping understands strings and both comment forms`() {
        val src = "val a = \"x // y /* z */\" // gone\n/* gone\n too */ val b = 1 /* gone */ + 2"
        assertEquals("val a = \"x // y /* z */\" \n  val b = 1   + 2", stripComments(src))
    }

    companion object {
        /** Removes `//` and `/* */` comments (nested too), leaving string literals as they are. */
        fun stripComments(s: String): String {
            val out = StringBuilder()
            var i = 0
            while (i < s.length) {
                when {
                    s[i] == '"' -> {
                        val start = i
                        i++
                        while (i < s.length && s[i] != '"') i += if (s[i] == '\\') 2 else 1
                        i = minOf(i + 1, s.length)
                        out.append(s, start, i)
                    }
                    s.startsWith("//", i) -> while (i < s.length && s[i] != '\n') i++
                    s.startsWith("/*", i) -> {
                        var depth = 1
                        i += 2
                        while (i < s.length && depth > 0) {
                            when {
                                s.startsWith("/*", i) -> { depth++; i += 2 }
                                s.startsWith("*/", i) -> { depth--; i += 2 }
                                else -> i++
                            }
                        }
                        out.append(' ')
                    }
                    else -> { out.append(s[i]); i++ }
                }
            }
            return out.toString()
        }
    }
}
