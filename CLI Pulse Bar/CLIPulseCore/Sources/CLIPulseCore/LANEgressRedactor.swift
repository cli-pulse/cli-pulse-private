import Foundation

/// The last thing that touches terminal bytes before they leave this Mac.
///
/// WHY THIS EXISTS — the helper does NOT redact the live stream.
///
/// It is natural to assume redaction already happened upstream, because
/// `get_tail_snapshot` genuinely is redacted (`ManagedSessionManager
/// .getTailSnapshot` runs `Redactor.redact` before returning). The live
/// `subscribe_events` path is not: `ManagedSessionManager`'s drain loop
/// publishes the verbatim decoded PTY chunk as `output_delta`, and
/// `Redactor` appears nowhere on that path. So the catch-up snapshot and
/// the live stream of the SAME bytes have opposite secrecy properties.
///
/// That asymmetry was harmless while the only subscriber was the in-app
/// terminal on the same Mac — the user looking at their own screen. It
/// stops being harmless the moment those bytes cross a network to a
/// phone, which is exactly what the LAN transport does.
///
/// Worse, the two helper implementations that can own the same socket
/// disagree with each other:
///
///   | helper                       | `output_delta`        | `output_raw` |
///   |------------------------------|-----------------------|--------------|
///   | Python `.pkg`                | redacted + ANSI-stripped | raw, opt-in |
///   | Swift bundled (the default)  | **verbatim**          | not implemented |
///
/// So the transport cannot infer safety from the event name, and
/// `subscribeEvents(raw:)` does not select between them on the bundled
/// helper — that parameter is simply not read there. The only defensible
/// position is that the egress path redacts unconditionally, regardless
/// of which helper answered and which event kind arrived.
///
/// Idempotence is what makes that safe: redacting already-redacted text
/// is a no-op (the marker matches no pattern), so double-redaction on
/// the Python helper's already-clean output costs correctness nothing.
///
/// ── Two hazards this handles that a plain `redact(chunk)` does not ──
///
/// **1. Chunk boundaries.** PTY output is delivered in slices whose
/// boundaries fall wherever the `read(2)` landed, not on anything
/// semantic. A secret split across two `output_delta` frames matches
/// nothing in either frame. Use `Streaming` rather than `redact` for
/// anything arriving in chunks — see its own docs for the carry rule.
///
/// **2. ANSI interleaving.** The patterns match literal text, so
/// `sk-ant-<esc>[0m...` defeats them while still rendering as the secret
/// in any terminal emulator. `redact` therefore ALSO tests an
/// ANSI-stripped copy, and if stripping reveals a secret the raw pass
/// missed, it fails closed on the whole span rather than emitting it.
public enum LANEgressRedactor {

    /// Same marker HelperKit's `Redactor` and `helper/redaction.py` use,
    /// so redacted text looks identical whichever layer caught it.
    public static let redactionMarker = "«REDACTED»"

    /// What `redact` replaces a span with when the ANSI cross-check trips
    /// — i.e. a secret was visible only after escape sequences were
    /// stripped, so we cannot know which byte ranges to blank.
    public static let failClosedReplacement = "«REDACTED — line withheld»\r\n"

    // MARK: - One-shot

    /// Redact `text`, failing closed on ANSI-obfuscated secrets.
    ///
    /// Idempotent: `redact(redact(x)) == redact(x)`.
    public static func redact(_ text: String) -> String {
        if text.isEmpty { return text }

        let direct = applyPatterns(text)

        // ANSI cross-check. If the escape-stripped copy yields MORE
        // redactions than the raw pass did, at least one secret was
        // hidden behind escape sequences. We cannot map those matches
        // back onto raw byte ranges (stripping changed the offsets), so
        // withhold the affected span entirely rather than emit a secret
        // we have positively detected.
        let stripped = AnsiSanitizer.strip(text)
        if stripped != text {
            let strippedRedacted = applyPatterns(stripped)
            if markerCount(strippedRedacted) > markerCount(direct) {
                return failClosed(text)
            }
        }
        return direct
    }

    /// Fail-closed replacement, line-granular so an interactive TUI keeps
    /// most of its screen when one line trips the cross-check.
    private static func failClosed(_ text: String) -> String {
        var out = ""
        out.reserveCapacity(text.count)
        // Keep line structure: only lines whose stripped form redacts
        // differently from their raw form are withheld.
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let s = String(line)
            let direct = applyPatterns(s)
            let strippedRedacted = applyPatterns(AnsiSanitizer.strip(s))
            if markerCount(strippedRedacted) > markerCount(direct) {
                out += failClosedReplacement
            } else {
                out += direct + "\n"
            }
        }
        if !text.hasSuffix("\n"), out.hasSuffix("\n") {
            out.removeLast()
        }
        return out
    }

    private static func markerCount(_ s: String) -> Int {
        guard !s.isEmpty else { return 0 }
        return s.components(separatedBy: redactionMarker).count - 1
    }

    // MARK: - Streaming

    /// Chunk-boundary-safe wrapper around `redact`.
    ///
    /// THE RULE: never emit text we are not confident is complete.
    ///
    /// Every pattern in the set is line-scoped — the value alternations
    /// (`[^\s'",;}]+`, `[^"'\r\n]+`, `\S+`) all stop at whitespace or a
    /// newline — so text before the last newline cannot be extended by
    /// bytes that have not arrived yet. Everything after the last newline
    /// is held back and re-scanned joined with the next chunk.
    ///
    /// `maxCarry` is the safety valve for a stream that legitimately has
    /// no newline for a long time (a progress bar redrawing with `\r`).
    /// When the carry exceeds it we force-emit, but still hold back
    /// `overlapWindow` characters so a token straddling the forced cut is
    /// not split. That window must exceed the longest matchable secret;
    /// JWTs are the long case, hence 512 rather than a round 64.
    ///
    /// Carry is kept in the ORIGINAL text domain, never the redacted one:
    /// redaction changes string lengths, so mixing the two coordinate
    /// spaces would corrupt offsets and could emit a fragment twice.
    public struct Streaming {
        public static let defaultMaxCarry = 8192
        public static let defaultOverlapWindow = 512

        private var carry: String = ""
        private let maxCarry: Int
        private let overlapWindow: Int

        public init(maxCarry: Int = Streaming.defaultMaxCarry,
                    overlapWindow: Int = Streaming.defaultOverlapWindow) {
            // An overlap at least as large as the carry would never emit.
            self.maxCarry = max(maxCarry, 1)
            self.overlapWindow = max(0, min(overlapWindow, max(maxCarry, 1) - 1))
        }

        /// Feed one PTY chunk; returns the text that is safe to send now
        /// (possibly empty — that is normal, not an error).
        public mutating func submit(_ chunk: String) -> String {
            if chunk.isEmpty { return "" }
            var buffer = carry + chunk

            // Primary rule: emit through the last newline.
            if let lastNewline = buffer.lastIndex(of: "\n") {
                let cut = buffer.index(after: lastNewline)
                let complete = String(buffer[buffer.startIndex..<cut])
                carry = String(buffer[cut...])
                // The carry itself may now exceed the cap.
                if carry.count > maxCarry {
                    let forced = forceEmit(&carry)
                    return LANEgressRedactor.redact(complete + forced)
                }
                return LANEgressRedactor.redact(complete)
            }

            // No newline at all. Hold everything unless we are over cap.
            if buffer.count > maxCarry {
                let forced = forceEmit(&buffer)
                carry = buffer
                return LANEgressRedactor.redact(forced)
            }
            carry = buffer
            return ""
        }

        /// Emit everything held back. Call on session end / disconnect —
        /// otherwise the tail of the last line is never sent.
        public mutating func flush() -> String {
            if carry.isEmpty { return "" }
            let out = LANEgressRedactor.redact(carry)
            carry = ""
            return out
        }

        /// True when bytes are being held. Useful in tests and for a
        /// disconnect path that must decide whether to flush.
        public var hasPendingBytes: Bool { !carry.isEmpty }

        /// Cut `buffer` at `count - overlapWindow`, returning the prefix
        /// and leaving the retained suffix in `buffer`.
        private func forceEmit(_ buffer: inout String) -> String {
            let keep = min(overlapWindow, buffer.count)
            let cutOffset = buffer.count - keep
            let cut = buffer.index(buffer.startIndex, offsetBy: cutOffset)
            let prefix = String(buffer[buffer.startIndex..<cut])
            buffer = String(buffer[cut...])
            return prefix
        }
    }

    // MARK: - Patterns

    /// Ported from `HelperSwift/Sources/HelperKit/Redactor.swift`, which
    /// in turn mirrors `helper/redaction.py`. CLIPulseCore cannot import
    /// HelperKit (it is not a package dependency — see Package.swift), so
    /// this is a copy, and a copy of a security-critical constant needs a
    /// drift gate: `LANEgressRedactorDriftTests` reads the HelperKit
    /// source at test time and fails if the two lists diverge. Add a
    /// pattern THERE first, then here.
    static func applyPatterns(_ text: String) -> String {
        var s = text
        for (pattern, opts) in lineKeyPatterns {
            s = applyRegex(s, pattern: pattern, options: opts,
                           replacement: "$1\(redactionMarker)")
        }
        for (pattern, opts) in tokenShapePatterns {
            s = applyRegex(s, pattern: pattern, options: opts,
                           replacement: redactionMarker)
        }
        return s
    }

    static let lineKeyPatterns: [(String, NSRegularExpression.Options)] = [
        ("((?:^|[\\s'\"])authorization\\s*:\\s*)[^\"'\\r\\n]+", [.caseInsensitive]),
        ("((?:^|[\\s'\"])proxy-authorization\\s*:\\s*)[^\"'\\r\\n]+", [.caseInsensitive]),
        ("((?:^|[\\s'\"])cookie\\s*:\\s*)[^\"'\\r\\n]+", [.caseInsensitive]),
        ("((?:^|[\\s'\"])set-cookie\\s*:\\s*)[^\"'\\r\\n]+", [.caseInsensitive]),
        ("((?:^|[\\s'\"])x-api-key\\s*:\\s*)[^\"'\\r\\n]+", [.caseInsensitive]),

        ("\\b(access[_-]?token['\"]?\\s*[:=]\\s*['\"]?)[^\\s'\",;}]+", [.caseInsensitive]),
        ("\\b(refresh[_-]?token['\"]?\\s*[:=]\\s*['\"]?)[^\\s'\",;}]+", [.caseInsensitive]),
        ("\\b(id[_-]?token['\"]?\\s*[:=]\\s*['\"]?)[^\\s'\",;}]+", [.caseInsensitive]),
        ("\\b(session[_-]?key['\"]?\\s*[:=]\\s*['\"]?)[^\\s'\",;}]+", [.caseInsensitive]),
        ("\\b(client[_-]?secret['\"]?\\s*[:=]\\s*['\"]?)[^\\s'\",;}]+", [.caseInsensitive]),
        ("\\b(api[_-]?key['\"]?\\s*[:=]\\s*['\"]?)[^\\s'\",;}]+", [.caseInsensitive]),
        ("\\b(secret[_-]?key['\"]?\\s*[:=]\\s*['\"]?)[^\\s'\",;}]+", [.caseInsensitive]),
        ("\\b(private[_-]?key['\"]?\\s*[:=]\\s*['\"]?)[^\\s'\",;}]+", [.caseInsensitive]),
        ("\\b(helper[_-]?secret['\"]?\\s*[:=]\\s*['\"]?)[^\\s'\",;}]+", [.caseInsensitive]),
        ("\\b(password['\"]?\\s*[:=]\\s*['\"]?)[^\\s'\",;}]+", [.caseInsensitive]),
        ("\\b(passwd['\"]?\\s*[:=]\\s*['\"]?)[^\\s'\",;}]+", [.caseInsensitive]),

        ("\\b([A-Z][A-Z0-9_]*_(?:TOKEN|KEY|SECRET|PASSWORD|PASSWD)\\s*=\\s*)\\S+", []),
    ]

    static let tokenShapePatterns: [(String, NSRegularExpression.Options)] = [
        ("sk-[A-Za-z0-9_\\-]{8,}", []),
        ("sk-ant-[A-Za-z0-9_\\-]{8,}", []),
        ("AIza[0-9A-Za-z_\\-]{20,}", []),
        ("ghp_[A-Za-z0-9]{20,}", []),
        ("github_pat_[A-Za-z0-9_]{20,}", []),
        ("[sr]k_(?:live|test)_[A-Za-z0-9]{16,}", []),
        ("pk_(?:live|test)_[A-Za-z0-9]{16,}", []),
        ("xox[abprs]-[A-Za-z0-9-]{10,}", []),
        ("npm_[A-Za-z0-9]{16,}", []),
        ("pypi-[A-Za-z0-9_\\-]{16,}", []),
        ("AKIA[0-9A-Z]{12,}", []),
        ("Bearer\\s+[A-Za-z0-9._\\-]{16,}", [.caseInsensitive]),
        ("eyJ[A-Za-z0-9_\\-]{4,}\\.[A-Za-z0-9_\\-]{4,}\\.[A-Za-z0-9_\\-]{4,}", []),
        ("\\b[A-Fa-f0-9]{56,}\\b", []),
    ]

    private static func applyRegex(
        _ text: String,
        pattern: String,
        options: NSRegularExpression.Options,
        replacement: String
    ) -> String {
        guard let re = try? NSRegularExpression(pattern: pattern, options: options) else {
            return text
        }
        let nsText = text as NSString
        return re.stringByReplacingMatches(
            in: text,
            options: [],
            range: NSRange(location: 0, length: nsText.length),
            withTemplate: replacement
        )
    }
}
