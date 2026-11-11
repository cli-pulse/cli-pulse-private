package com.clipulse.android.util

import com.clipulse.android.repoFile
import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Release builds keep every Log call (no ProGuard stripping), so a log line is a disclosure.
 *
 * In `fcm/`, `worker/` and `data/remote/` every `Log.<level>(` call must have this exact shape:
 * two arguments, a tag and ONE ordinary (not raw `"""`) string literal. The only things the
 * literal may interpolate are the expressions in an explicit allowlist (`signedIn`, `status`,
 * `results.size`, `payloads.size`, `r.code`, `e.javaClass.simpleName`, `failureSummary(e)`).
 * Any other `$name` or `${expression}` fails whatever it is called, so throwable arguments,
 * `${e.toString()}`, renamed exceptions (`$failure`), `$body`, `$url` and string concatenation are
 * all rejected. Calls are found with a balanced-parenthesis scanner that understands Kotlin strings,
 * templates and char literals, and import forms that would let a call dodge the scan
 * (`import ... as`, member imports) are rejected everywhere.
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
                '\'' -> i = skipChar(s, i)
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
                '\'' -> { i = skipChar(s, i); continue }
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

    /** The only expressions a log message may interpolate. Anything else, whatever its name, fails. */
    private val allowedInterpolations = setOf(
        "signedIn", "status", "results.size", "payloads.size", "r.code",
        "e.javaClass.simpleName", "failureSummary(e)",
    )

    /** [start] is at a single quote; returns the index just after the char literal. */
    private fun skipChar(s: String, start: Int): Int {
        if (s.getOrNull(start + 1) == '\\') {
            val end = s.indexOf('\'', start + 3)
            return if (end < 0) s.length else end + 1
        }
        return if (s.getOrNull(start + 2) == '\'') start + 3 else start + 1
    }

    /** Splits the text between a call's outer parentheses at top-level commas. */
    private fun topLevelArgs(call: String): List<String> {
        val inner = call.substring(1, call.length - 1)
        val args = mutableListOf<String>()
        var depth = 0
        var start = 0
        var i = 0
        while (i < inner.length) {
            when (inner[i]) {
                '"' -> { i = skipString(inner, i); continue }
                '\'' -> { i = skipChar(inner, i); continue }
                '(', '[', '{' -> depth++
                ')', ']', '}' -> depth--
                ',' -> if (depth == 0) { args += inner.substring(start, i); start = i + 1 }
            }
            i++
        }
        args += inner.substring(start)
        return args.map { it.trim() }.filter { it.isNotEmpty() }
    }

    /** Null when the call has a permitted shape, otherwise the reason it does not. */
    private fun violation(call: String): String? {
        val args = topLevelArgs(call)
        if (args.size != 2) return "must have exactly two arguments (tag, message); a throwable argument logs its stack: ${normalized(call)}"
        val message = args[1]
        if (message.startsWith("\"\"\"")) return "raw string literals are not allowed in log messages: ${normalized(call)}"
        if (!message.startsWith("\"") || skipString(message, 0) != message.length) {
            return "message must be a single string literal: ${normalized(call)}"
        }
        var i = 1
        while (i < message.length - 1) {
            when {
                message[i] == '\\' -> i += 2
                message[i] == '$' && message.getOrNull(i + 1) == '{' -> {
                    val end = skipBraces(message, i + 2)
                    val expr = message.substring(i + 2, end - 1).trim()
                    if (expr !in allowedInterpolations) return "interpolation \${$expr} is not on the allowlist: ${normalized(call)}"
                    i = end
                }
                message[i] == '$' && message.getOrNull(i + 1)?.let { it.isLetter() || it == '_' } == true -> {
                    var j = i + 1
                    while (j < message.length && (message[j].isLetterOrDigit() || message[j] == '_')) j++
                    val name = message.substring(i + 1, j)
                    if (name !in allowedInterpolations) return "\$$name is not on the allowlist: ${normalized(call)}"
                    i = j
                }
                else -> i++
            }
        }
        return null
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
            val reason = violation(call)
            assertTrue("$dir/${f.name}: $reason", reason == null)
        }
    }

    @Test
    fun `the allowlist rejects throwable overloads and renamed variables`() {
        val bad = listOf(
            "(TAG, \"failed\", e)",
            "(TAG, \"failed\", exception)",
            "(TAG, \"failed \${e.toString()}\")",
            "(TAG, \"failed \$err\")",
            "(TAG, \"failed \${boom}\" + other)",
            "(TAG, \"failed \${ex.message}\")",
            "(TAG,\n  \"id \$deviceId\")",
            "(TAG, \"x \${tokenStore.deviceId}\")",
            "(TAG, \"failed \$failure\")",
            "(TAG, \"failed \${failure}\")",
            "(TAG, \"r \$body\")",
            "(TAG, \"r \$message\")",
            "(TAG, \"r \$msg\")",
            "(TAG, \"r \$url\")",
            "(TAG, \"r \$email\")",
            "(TAG, \"r \$response\")",
            "(TAG, \"\"\"failed \\\$failure\"\"\")",
            "(TAG, \"\"\"failed \${failure}\"\"\")",
            "(TAG, \"\"\"plain\"\"\")",
        )
        for (c in bad) assertTrue("should be rejected: $c", violation(c) != null)
        val good = listOf(
            "(TAG, \"plain\")",
            "(TAG, \"n=\${results.size} s=\$status\")",
            "(TAG, \"x \${e.javaClass.simpleName}\")",
            "(TAG, \"x \${failureSummary(e)}\")",
        )
        for (c in good) assertEquals("should be accepted: $c", null, violation(c))
    }

    @Test
    fun `the scanner skips quote characters`() {
        val src = "('\"', \"x\") + more(\")\")"
        assertEquals("('\"', \"x\")", balancedCall(src, 0))
        assertEquals(listOf("'\"'", "\"x\""), topLevelArgs("('\"', \"x\")"))
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
