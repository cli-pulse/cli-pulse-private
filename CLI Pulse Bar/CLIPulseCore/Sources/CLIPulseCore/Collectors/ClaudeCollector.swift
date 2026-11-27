#if os(macOS)
import Foundation
import Security

/// Fetches real usage/quota data from Claude (Anthropic) via a multi-source strategy chain.
///
/// Strategy priority (configurable via `ProviderConfig.sourceMode`):
/// 1. **OAuth API** — `GET https://api.anthropic.com/api/oauth/usage`
/// 2. **Web session** — `claude.ai/api/organizations/.../usage` via manual cookie header
/// 3. **CLI PTY** — runs `claude /usage` in a pseudo-terminal, handles TUI prompts
///
/// Each strategy is tried in order; failures trigger fallback to the next strategy.
/// DEBUG builds log the chain to `$TMPDIR/clipulse_claude_resolver.log`; release builds write no file (1.59).
public struct ClaudeCollector: ProviderCollector, Sendable {
    public let kind = ProviderKind.claude

    private let resolver: ClaudeSourceResolver

    /// - Parameter resolver: tests pass one with their own strategies.
    init(resolver: ClaudeSourceResolver = ClaudeSourceResolver()) {
        self.resolver = resolver
    }

    public func isAvailable(config: ProviderConfig) -> Bool {
        resolver.isAvailable(config: config)
    }

    /// Say WHY when the machine-wide Claude login belongs to another account
    /// entry. `resolveTokenDetails` refuses that case before it reads any
    /// credential source, so `isAvailable` goes false while the user is
    /// perfectly signed in — and the default reason renders as "Not set up",
    /// which sends them to a Settings screen that already says Connected.
    ///
    /// 1.59 (59-15 F2): and say why otherwise too. The token resolver notes
    /// where it stopped in a `ClaudeTokenResolutionLog` bound around this
    /// call's own `isAvailable`, and `ClaudeNotReadyDiagnosis` names it:
    /// declined in macOS's dialog, disconnected, Strict privacy mode, no
    /// Claude.ai login on this Mac, Claude Code not installed. `.unknown` is
    /// left for what really is unknown.
    public func readiness(config: ProviderConfig) -> CollectorReadiness {
        let resolution = ClaudeTokenResolutionLog()
        let available = ClaudeTokenResolutionLog.$current.withValue(resolution) {
            isAvailable(config: config)
        }
        if available { return .ready }
        if let conflict = CollectorReadinessProbe.sharedCredentialConflict(
            kind: .claude, accountID: config.accountID
        ) { return conflict }
        return .notReady(ClaudeNotReadyDiagnosis.reason(for: resolution.absence))
    }

    /// 1.63.3: a run in which every strategy failed because Claude Code's own
    /// login cannot be used says so, as `readiness` does when nothing else can
    /// run ("Not signed in", "Keychain access declined"), rather than "Check
    /// failed — This one is on us". The resolution log is bound here as
    /// `readiness` binds it around `isAvailable`: the OAuth strategy notes why
    /// it had no token, or that the token it sent was refused.
    public func collect(config: ProviderConfig) async throws -> CollectorResult {
        let resolution = ClaudeTokenResolutionLog()
        do {
            return try await ClaudeTokenResolutionLog.$current.withValue(resolution) {
                try await resolver.resolveKeepingFailures(config: config)
            }
        } catch let exhausted as ClaudeStrategiesExhausted {
            if let reason = ClaudeNotReadyDiagnosis.reason(
                forFailedRun: exhausted.failures, absence: resolution.absence
            ) {
                throw CollectorNotReadyFailure(
                    reason: reason, providerName: kind.rawValue, underlying: exhausted.primary)
            }
            throw exhausted.primary
        }
    }

    // MARK: - Backward-compatible static methods (used by tests)

    /// Parse OAuth usage JSON response.
    static func parseUsage(_ data: Data) throws -> ClaudeOAuthStrategy.OAuthUsageResponse {
        try ClaudeOAuthStrategy.parseUsage(data)
    }

    /// Parse credentials JSON (snake_case or camelCase).
    static func parseCredentialsJSON(_ data: Data) -> ClaudeCredentials.Creds? {
        ClaudeCredentials.parseCredentialsJSON(data)
    }

    /// Strip ANSI escape codes.
    static func stripANSI(_ text: String) -> String {
        ClaudeCredentials.stripANSI(text)
    }

    /// Extract percentage from line with used/left semantics.
    static func percentUsedFromLine(_ line: String) -> Int? {
        ClaudeCLIPTYStrategy.percentUsedFromLine(line)
    }

    /// Parse raw CLI output into a snapshot.
    static func parseCLIOutput(_ text: String) throws -> ClaudeCLIPTYStrategy.CLISnapshot {
        try ClaudeCLIPTYStrategy.parseCLIOutput(text)
    }

    /// Find the claude CLI binary.
    func findClaudeBinary() -> String? {
        ClaudeCLIPTYStrategy.findClaudeBinary()
    }

    /// Typealias for test compatibility.
    typealias UsageResponse = ClaudeOAuthStrategy.OAuthUsageResponse
    typealias CLISnapshot = ClaudeCLIPTYStrategy.CLISnapshot
    typealias CaudeCreds = ClaudeCredentials.Creds

    struct ClaudeCreds {
        let accessToken: String
        let rateLimitTier: String?
    }
}
#endif
