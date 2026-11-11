package com.clipulse.android.util

import com.clipulse.android.repoFile
import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Release builds keep every Log call (no ProGuard stripping), so a log line is a disclosure.
 * Parses each `Log.<level>(` call with a balanced-parenthesis scanner that understands Kotlin
 * strings and `${}` templates, so multi-line calls and renamed variables are covered, and
 * rejects import forms that would let a call dodge the scan (`import ... as`, member imports).
 */
class NoIdentifierLoggingTest {
    private val sourceRoot = "src/main/java/com/clipulse/android"
    private val guardedDirs = listOf("fcm", "worker", "data/remote")

    private val logCall = Regex("""\bLog\.(v|d|i|w|e|wtf)\s*\(""")
    private val aliasImport = Regex("""import\s+android\.util\.Log\s+as\b""")
    private val memberImport = Regex("""import\s+android\.util\.Log\.""")

    private val forbiddenIdentifier = Regex(
        """\b(deviceId|device_id|userId|user_id|accessToken|refreshToken|pushToken|token)\b""",
        RegexOption.IGNORE_CASE,
    )
    private val throwableText = Regex(
        """\.message\b|\.localizedMessage\b|\$(e|ex|t|err|error|throwable)\b|\$\{\s*(e|ex|t|err|error|throwable)\s*\}""",
    )

    // ---- scanner ---------------------------------------------------------------------------

    /** [start] is at an opening quote; returns the index just after the closing quote. */
    private fun skipString(s: String, start: Int): Int {
        if (s.startsWith("\"\"\"", start)) {
            val end = s.indexOf("\"\"\"", start + 3)
            return if (end < 0) s.length else end + 3
        }
        var i = start + 1
        while (i < s.length) {
            when (s[i]) {
                '\\' -> i += 2
                '"' -> return i + 1
                '$' -> i = if (s.getOrNull(i + 1) == '{') skipBraces(s, i + 2) else i + 1
                else -> i++
            }
        }
        return s.length
    }

    /** [start] is just after `{`; returns the index just after the matching `}`. */
    private fun skipBraces(s: String, start: Int): Int {
        var depth = 1
        var i = start
        while (i < s.length) {
            when (s[i]) {
                '"' -> i = skipString(s, i)
                '{' -> { depth++; i++ }
                '}' -> { depth--; i++; if (depth == 0) return i }
                else -> i++
            }
        }
        return s.length
    }

    /** [open] is the index of `(`; returns the whole call text from `(` to its matching `)`. */
    private fun balancedCall(s: String, open: Int): String {
        var depth = 0
        var i = open
        while (i < s.length) {
            when (s[i]) {
                '"' -> { i = skipString(s, i); continue }
                '(' -> depth++
                ')' -> { depth--; if (depth == 0) return s.substring(open, i + 1) }
            }
            i++
        }
        return s.substring(open)
    }

    /**
     * What the call can actually emit besides fixed words: code outside strings, plus the
     * `$name` and `${expression}` parts inside strings. Literal text is dropped, so the word
     * "token" in "FCM token refreshed" is not an identifier.
     */
    private fun emittedExpressions(call: String): String {
        val out = StringBuilder()
        var i = 0
        while (i < call.length) {
            val c = call[i]
            if (c != '"') { out.append(c); i++; continue }
            i++
            while (i < call.length && call[i] != '"') {
                when {
                    call[i] == '\\' -> i += 2
                    call[i] == '$' && call.getOrNull(i + 1) == '{' -> {
                        val end = skipBraces(call, i + 2)
                        out.append("\${").append(call, i + 2, end).append(' ')
                        i = end
                    }
                    call[i] == '$' && call.getOrNull(i + 1)?.let { it.isLetter() || it == '_' } == true -> {
                        var j = i + 1
                        while (j < call.length && (call[j].isLetterOrDigit() || call[j] == '_')) j++
                        out.append(call, i, j).append(' ')
                        i = j
                    }
                    else -> i++
                }
            }
            i++
        }
        return out.toString()
    }

    private fun calls(file: File): List<String> {
        val text = file.readText()
        return logCall.findAll(text).map { balancedCall(text, it.range.last) }.toList()
    }

    private fun kotlinFiles(dir: String): List<File> =
        repoFile("$sourceRoot/$dir").walkTopDown().filter { it.isFile && it.extension == "kt" }.toList()

    private fun normalized(call: String) = call.replace(Regex("""\s+"""), " ")

    // ---- tests -----------------------------------------------------------------------------

    @Test
    fun `scanner understands multi line calls and templates`() {
        val src = "Log.w(TAG,\n  \"a \${x.y(\"q\")} ) b \$deviceId\",\n  e)"
        val call = balancedCall(src, src.indexOf('('))
        assertEquals(src.substring(src.indexOf('(')), call)
        val emitted = emittedExpressions(call)
        assertTrue(emitted, forbiddenIdentifier.containsMatchIn(emitted))
    }

    @Test
    fun `no import form lets a log call dodge the scan`() {
        for (f in kotlinFiles("")) {
            val text = f.readText()
            assertTrue("${f.name}: aliased import of android.util.Log", !aliasImport.containsMatchIn(text))
            assertTrue("${f.name}: member import of android.util.Log", !memberImport.containsMatchIn(text))
        }
    }

    private fun assertDirClean(dir: String) {
        for (f in kotlinFiles(dir)) for (call in calls(f)) {
            val emitted = emittedExpressions(call)
            assertTrue(
                "$dir/${f.name}: log call emits an identifier: ${normalized(call)}",
                !forbiddenIdentifier.containsMatchIn(emitted),
            )
            assertTrue(
                "$dir/${f.name}: log call interpolates throwable text: ${normalized(call)}",
                !throwableText.containsMatchIn(emitted),
            )
        }
    }

    @Test
    fun `fcm log calls carry no identifiers or throwable text`() = assertDirClean("fcm")

    @Test
    fun `worker log calls carry no identifiers or throwable text`() = assertDirClean("worker")

    @Test
    fun `data remote log calls carry no identifiers or throwable text`() = assertDirClean("data/remote")

    @Test
    fun `the scan sees the existing log calls`() {
        val scanned = guardedDirs.sumOf { dir -> kotlinFiles(dir).sumOf { calls(it).size } }
        assertTrue("expected to scan the existing log calls, found $scanned", scanned >= 10)
    }

    @Test
    fun `the three known messages have exactly the redacted form`() {
        val sync = calls(repoFile("$sourceRoot/worker/SyncWorker.kt")).map(::normalized)
        assertTrue(sync.toString(), "(TAG, \"Registered Android device\")" in sync)

        val push = calls(repoFile("$sourceRoot/fcm/PushService.kt")).map(::normalized)
        assertTrue(push.toString(), "(TAG, \"Push token registered\")" in push)
        assertTrue(push.toString(), "(TAG, \"Skipping push token upload: signedIn=\$signedIn\")" in push)
        assertTrue(
            push.toString(),
            "(TAG, \"Failed to register push token: \${e.javaClass.simpleName} status=\$status\")" in push,
        )
    }
}
