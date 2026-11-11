package com.clipulse.android.util

import java.util.Collections
import java.util.IdentityHashMap

/**
 * Pure redaction helpers for crash reports (no Sentry types, so JVM tests reach every branch).
 * Mirrors the Apple apps' `SentryLogger.redact`: secrets, UUIDs, e-mail addresses, and the
 * query/fragment of any web address.
 */
internal object SentryScrub {

    /** Values under a key containing one of these are replaced wholesale, at every nesting level. */
    val SENSITIVE_KEY_FRAGMENTS = listOf(
        "password", "secret", "token", "apikey", "api_key",
        "authorization", "bearer",
        "supabase", "claude_api", "anthropic", "codex", "openai", "gemini", "dsn",
        "device_token", "pairing", "refresh_token", "access_token", "id_token",
        "keychain"
    )

    /** Containers nested deeper than this are replaced by [TRUNCATED]. */
    const val MAX_DEPTH = 8
    const val TRUNCATED = "[truncated]"
    const val SCRUBBED = "[scrubbed]"

    private val SECRET_PATTERNS = listOf(
        Regex("""eyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}"""),
        Regex("""(?<![A-Za-z0-9])sk-[A-Za-z0-9_-]{20,}"""),
        Regex("""(?<![A-Za-z0-9])sk_(live|test)_[A-Za-z0-9]{16,}"""),
        Regex("""(?i)\bbearer\s+\S+""")
    )

    private val UUID_PATTERN =
        Regex("""[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}""")

    private val EMAIL_PATTERN = Regex("""(?<![A-Za-z0-9._%+-])[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}""")

    // scheme://authority/path (any character except whitespace, "?" and "#": an apostrophe is a legal
    // path character), then a query or fragment that is dropped whole: once the "?" or "#"
    // starts, EVERYTHING up to whitespace or the end of the text goes. Whitespace is the only
    // terminator because every other character (quotes, brackets, angle brackets, commas) is legal
    // inside a query, and any other rule leaves the next parameter behind. The price is that
    // quotes or brackets from surrounding prose or JSON that touch the URL are dropped with it.
    // "?[query]" matches itself, so a second pass changes nothing. The left boundary keeps the
    // scan linear: a match can only start at the beginning of a scheme token.
    private val URL_QUERY_PATTERN =
        Regex("""(?<![A-Za-z0-9+.-])([A-Za-z][A-Za-z0-9+.-]*://[^\s?#]*)([?#])\S*""")

    /** Inputs longer than this are cut (and marked) before any pattern runs, bounding the work. */
    const val MAX_REDACT_CHARS = 8192

    fun shouldScrub(key: String): Boolean {
        val lower = key.lowercase()
        return SENSITIVE_KEY_FRAGMENTS.any { lower.contains(it) }
    }

    /**
     * The first [MAX_REDACT_CHARS] characters minus a trailing partial token: a secret cut by the cap
     * could fall below its pattern's minimum length and survive, so everything after the last
     * whitespace of the kept part is dropped (a complete last token goes too; that is harmless).
     * The kept part therefore ends in whitespace (or is empty), so the marker that follows it is its own
     * token and a URL query cannot swallow it; that also keeps a second pass stable.
     */
    private fun completeTokens(input: String): String {
        val kept = input.take(MAX_REDACT_CHARS)
        return kept.substring(0, kept.indexOfLast { it.isWhitespace() } + 1)
    }

    fun redact(input: String): String {
        if (input.length > MAX_REDACT_CHARS) return redact(completeTokens(input)) + TRUNCATED
        // URLs first, so a placeholder inserted by a later step can never end a query early.
        var out = URL_QUERY_PATTERN.replace(input) { m -> "${m.groupValues[1]}${m.groupValues[2]}[query]" }
        for (pattern in SECRET_PATTERNS) out = pattern.replace(out, SCRUBBED)
        out = UUID_PATTERN.replace(out, "[id]")
        out = EMAIL_PATTERN.replace(out, "[email]")
        return out
    }

    /**
     * Returns a scrubbed copy of [value]. A sensitive [key] replaces the value at any level;
     * strings are redacted; maps and iterables/arrays are rebuilt recursively (depth limit and
     * identity-based cycle detection); other types (numbers, booleans, SDK objects) are unchanged.
     */
    fun scrubValue(
        key: String?,
        value: Any?,
        depth: Int = 0,
        path: MutableSet<Any> = Collections.newSetFromMap(IdentityHashMap<Any, Boolean>()),
    ): Any? {
        if (key != null && shouldScrub(key)) return SCRUBBED
        return when (value) {
            null -> null
            is String -> redact(value)
            is Map<*, *> -> container(value, depth, path) {
                val out = LinkedHashMap<String, Any?>()
                for ((k, v) in value) {
                    val raw = k.toString()
                    // Keys are redacted like values; two keys that collide afterwards both stay.
                    val base = redact(raw)
                    var name = base
                    var n = 2
                    while (out.containsKey(name)) name = "$base#${n++}"
                    out[name] = scrubValue(raw, v, depth + 1, path)
                }
                out
            }
            is Iterable<*> -> container(value, depth, path) {
                value.map { scrubValue(null, it, depth + 1, path) }
            }
            is Array<*> -> container(value, depth, path) {
                value.map { scrubValue(null, it, depth + 1, path) }
            }
            else -> value
        }
    }

    private inline fun container(
        node: Any,
        depth: Int,
        path: MutableSet<Any>,
        build: () -> Any,
    ): Any {
        if (depth > MAX_DEPTH || !path.add(node)) return TRUNCATED
        try {
            return build()
        } finally {
            path.remove(node)
        }
    }
}
