import Foundation

/// What the macOS menu bar item shows beside its icon, decided once and then
/// rendered twice: as terse text for the menu bar, and as words for VoiceOver.
///
/// The visible text has no room for nouns — "3", "72%", "▲12%", "≈" — and
/// leans on the icon beside it and on the display mode the user picked. A
/// VoiceOver user gets neither: the item is one accessibility element with its
/// children ignored, so it used to be announced as "CLI Pulse, 3" (3 of what?)
/// or "CLI Pulse, black up-pointing triangle 12 percent", in every language.
/// Resolving the readout once is what keeps the spoken label from drifting
/// away from what is on screen — including the pace verdict, which depends on
/// the clock.
public enum MenuBarReadout: Equatable, Sendable {
    /// Signed out or not paired: the bare app icon.
    case signedOut
    /// Signed in, but the chosen mode has nothing to show (icon mode, no data).
    case empty
    /// Unresolved alerts take precedence over every display mode.
    case unresolvedAlerts(Int)
    /// `.percent` mode: the most-used provider's REMAINING share.
    case percentLeft(provider: String, percent: Int)
    /// `.mostUsed` mode: the provider's name (its icon replaces the app's).
    case provider(String)
    /// `.pace` mode: a glyph for the bar ("▲12%"), a localized summary to speak.
    case pace(provider: String, glyph: String, summary: String)
    /// `.pace` mode with no pace verdict: the USED share — the opposite of
    /// `.percentLeft`, which is exactly what a bare "45%" cannot say.
    case percentUsed(provider: String, percent: Int)

    public static func resolve(
        isSignedIn: Bool,
        unresolvedAlertCount: Int,
        mode: MenuBarDisplayMode,
        mostUsedProvider: ProviderUsage?,
        now: Date = Date()
    ) -> MenuBarReadout {
        guard isSignedIn else { return .signedOut }
        if unresolvedAlertCount > 0 {
            return .unresolvedAlerts(unresolvedAlertCount)
        }
        switch mode {
        case .percent:
            if let top = mostUsedProvider, top.usagePercent > 0 {
                // The quota alert's rule, so "8%" here is its "(8% remaining)".
                return .percentLeft(
                    provider: top.provider,
                    percent: QuotaPercent.usedAndLeft(usedFraction: top.usagePercent).left)
            }
            return .empty
        case .mostUsed:
            guard let name = mostUsedProvider?.provider, !name.isEmpty else { return .empty }
            return .provider(name)
        case .pace:
            // v1.23 G4: CodexBar-parity pace forecast. Prefer the
            // ultra-compact engine label ("▲12%"/"▼8%"/"≈"); fall back
            // to the used-% rendering when the engine has no verdict
            // (non-Codex/Claude top provider, or no reset anchor).
            guard let top = mostUsedProvider else { return .empty }
            if let glyph = top.paceMenuLabel(now: now), let detail = top.paceDetail(now: now) {
                return .pace(
                    provider: top.provider,
                    glyph: glyph,
                    summary: L10n.usagePace.summaryLeftOnly(detail.leftLabel))
            }
            if top.usagePercent > 0 {
                // The quota alert's rule, so "93%" here is its "at 93%".
                return .percentUsed(
                    provider: top.provider,
                    percent: QuotaPercent.usedAndLeft(usedFraction: top.usagePercent).used)
            }
            return .empty
        case .icon:
            return .empty
        }
    }

    /// The text beside the menu bar icon. Numbers and glyphs only, so it needs
    /// no localization; the words live in `accessibilityLabel`.
    public var visibleText: String {
        switch self {
        case .signedOut, .empty:
            return ""
        case .unresolvedAlerts(let count):
            return "\(count)"
        case .percentLeft(_, let percent), .percentUsed(_, let percent):
            return "\(percent)%"
        case .provider(let name):
            return name
        case .pace(_, let glyph, _):
            return glyph
        }
    }

    /// The VoiceOver label: the app name, then what the number is, then
    /// "Offline" when the server is unreachable — the menu bar says that only
    /// with a `wifi.slash` icon, which a listener never hears.
    public func accessibilityLabel(serverOnline: Bool) -> String {
        var parts = [L10n.widget.appName]
        switch self {
        case .signedOut:
            return L10n.a11y.clauses(parts)
        case .empty:
            break
        case .unresolvedAlerts(let count):
            parts.append(L10n.intents.openAlerts(count))
        case .percentLeft(let provider, let percent):
            parts.append(L10n.a11y.percentRemaining(provider, percent))
        case .provider(let name):
            parts.append(name)
        case .pace(let provider, _, let summary):
            parts.append(contentsOf: [provider, summary])
        case .percentUsed(let provider, let percent):
            parts.append(L10n.a11y.percentUsed(provider, percent))
        }
        if !serverOnline {
            parts.append(L10n.common.offline)
        }
        return L10n.a11y.clauses(parts)
    }
}
