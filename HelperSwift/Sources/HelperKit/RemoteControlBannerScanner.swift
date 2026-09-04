import Foundation

/// Remote-control M1a — watches the start-up output of a managed
/// `claude --remote-control` session and reports either the session URL
/// Claude printed or the reason it refused.
///
/// Why this lives in the helper and not the Mac app: the URL has to be
/// available on the session ROW (`list_sessions`) for a phone that
/// connects after the banner scrolled by, and the helper is the only
/// process that sees every byte the PTY produced.
///
/// Sentences are the ones shipped in Claude Code 2.1.259 (read out of the
/// binary on 2026-09-04). They are matched on ANSI-stripped text with a
/// rolling window so a sentence or URL split across two PTY reads is still
/// seen. The first outcome latches; nothing later can change it, and a
/// byte budget bounds how long the scanner keeps looking.
public final class RemoteControlBannerScanner: @unchecked Sendable {

    public enum Reason: String, Sendable, Equatable {
        case notLoggedIn = "not_logged_in"
        case disabledByPolicy = "disabled_by_policy"
        case thirdPartyProvider = "third_party_provider"
        /// The byte budget ran out without a banner or a refusal.
        case noBannerSeen = "no_banner_seen"
        /// The manager's wall-clock deadline passed (set by the manager,
        /// never by the scanner itself).
        case timeout
        /// The user typed before a banner was seen (set by the manager).
        /// Output after user input is not a start-up banner; a URL there
        /// could be anything the session was asked to print.
        case inputBeforeBanner = "input_before_banner"
    }

    public enum Outcome: Equatable, Sendable {
        case ready(String)
        case unavailable(Reason)
    }

    private let budgetBytes: Int
    private let windowBytes: Int
    private let lock = NSLock()
    private var window = Data()
    private var consumed = 0
    private var latched: Outcome?

    public init(budgetBytes: Int = 1 << 20, windowBytes: Int = 8192) {
        self.budgetBytes = budgetBytes
        self.windowBytes = windowBytes
    }

    public var outcome: Outcome? {
        lock.lock(); defer { lock.unlock() }
        return latched
    }

    /// Feed one PTY read. Returns the outcome once known (and the same
    /// outcome on every later call), nil while still looking.
    @discardableResult
    public func feed(_ chunk: Data) -> Outcome? {
        lock.lock(); defer { lock.unlock() }
        if let latched { return latched }
        consumed += chunk.count
        window.append(chunk)
        if window.count > windowBytes * 2 {
            window = window.suffix(windowBytes)
        }
        let text = Self.stripANSI(String(decoding: window, as: UTF8.self)).replacingOccurrences(of: "\r", with: "")
        if let found = Self.match(text) {
            latched = found
            window = Data()
            return found
        }
        if consumed >= budgetBytes {
            latched = .unavailable(.noBannerSeen)
            window = Data()
            return latched
        }
        return nil
    }

    // MARK: - Matching

    private static let refusals: [(String, Reason)] = [
        ("You must be logged in to use Remote Control", .notLoggedIn),
        ("Remote Control is only available with claude.ai subscriptions", .notLoggedIn),
        ("Remote Control is disabled by your organization", .disabledByPolicy),
        ("Remote Control is only available when using Claude via api.anthropic.com", .thirdPartyProvider),
    ]

    /// `claude.ai/code/<id>` with an optional scheme and query. Path words
    /// that are Claude Code's OTHER `claude.ai/code/...` destinations (the
    /// artifacts gallery, routines, onboarding) are not session ids.
    private static let urlRegex = regex(
        #"(?:https?://)?claude\.ai/code/(?:session/)?([A-Za-z0-9_-]{6,})(\?[A-Za-z0-9=&_.%-]*)?"#)

    /// ICU syntax (`\x1b`, not Swift's `\u{1b}`); a bad pattern is a
    /// programming error, so it fails loudly at first use rather than
    /// silently matching nothing.
    private static func regex(_ pattern: String) -> NSRegularExpression {
        guard let r = try? NSRegularExpression(pattern: pattern) else {
            preconditionFailure("RemoteControlBannerScanner: invalid pattern \(pattern)")
        }
        return r
    }
    private static let notSessionIDs: Set<String> = ["artifacts", "artifact", "routines", "routine", "onboarding", "sessions", "session"]

    static func match(_ text: String) -> Outcome? {
        // A refusal that arrives with a URL in the same window cannot
        // happen (Claude prints one or the other), but check the
        // refusals first anyway: they are the fail-closed reading.
        for (needle, reason) in refusals where text.contains(needle) {
            return .unavailable(reason)
        }
        let ns = text as NSString
        for m in urlRegex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            // A match that runs to the very end of the window may be a
            // URL cut by the PTY read boundary — the every-byte-split
            // test caught exactly that (`…/code/019a2b` latched as the
            // whole URL). Claude always prints something after the URL
            // (a newline, a reset sequence), so wait for it.
            if m.range.location + m.range.length >= ns.length { continue }
            let id = ns.substring(with: m.range(at: 1))
            if notSessionIDs.contains(id.lowercased()) { continue }
            var url = "https://claude.ai/code/" + id
            if m.range(at: 2).location != NSNotFound {
                url += ns.substring(with: m.range(at: 2))
            }
            return .ready(url)
        }
        return nil
    }

    // MARK: - ANSI

    private static let ansiPatterns: [NSRegularExpression] = [
        // OSC: ESC ] ... (BEL | ESC \)
        #"\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)"#,
        // CSI: ESC [ params intermediates final
        #"\x1b\[[0-?]*[ -/]*[@-~]"#,
        // Charset selects and other two-byte escapes: ESC ( B, ESC = , …
        #"\x1b[()*+][A-Za-z0-9]"#,
        #"\x1b[@-Z\\-_]"#,
    ].map(regex)

    static func stripANSI(_ s: String) -> String {
        var out = s
        for re in ansiPatterns {
            out = re.stringByReplacingMatches(in: out, range: NSRange(location: 0, length: (out as NSString).length), withTemplate: "")
        }
        return out
    }
}
