import SwiftUI

/// Provider-aware display strings + glyphs for the Sessions UI.
/// Added in v1.15 (round-4 hardening) when the iOS user reported that
/// codex / gemini sessions still showed "Claude" everywhere — header,
/// row label, brain icon, orange provider color. Pre-v1.15 the entire
/// managed-sessions surface was Claude-only so hardcoding was fine;
/// v1.15 introduced multi-CLI but missed the rendering layer.
///
/// Usage from a SwiftUI row:
///
///     let label = session.client_label ?? ProviderDisplay.defaultLabel(for: session.provider)
///     Image(systemName: ProviderDisplay.iconSymbol(for: session.provider))
///         .foregroundStyle(ProviderDisplay.color(for: session.provider))
///     Text(label)
///
/// All accessors normalize the provider string (case-insensitive,
/// whitespace-trimmed) so "Claude" / "claude" / "  CLAUDE " all
/// resolve to the same surface.
public enum ProviderDisplay {
    /// Canonical display name. Pre-v1.15 callers passed `"Claude"`
    /// to `PulseTheme.providerColor`; this normalizer reuses that
    /// table so the orange/codex-blue/gemini-* palette stays in one
    /// place.
    public static func displayName(for provider: String) -> String {
        switch normalize(provider) {
        case "codex":  return "Codex"
        case "gemini": return "Gemini"
        default:       return "Claude"
        }
    }

    /// SF Symbol used for the provider's row glyph + the spawn-picker
    /// icon. Matches the picker (Claude=sparkles, Codex=chevron-slash,
    /// Gemini=diamond) so the same shape carries from picker → row →
    /// detail view.
    public static func iconSymbol(for provider: String) -> String {
        switch normalize(provider) {
        case "codex":  return "chevron.left.slash.chevron.right"
        case "gemini": return "diamond"
        default:       return "sparkles"
        }
    }

    /// Provider tint color. Delegates to `PulseTheme.providerColor`
    /// with the canonical capitalized name so the existing palette
    /// applies.
    public static func color(for provider: String) -> Color {
        PulseTheme.providerColor(displayName(for: provider))
    }

    /// Fallback used when the row's `client_label` is nil/empty.
    /// Pre-v1.15 every code path used the literal `"Claude session"`;
    /// post-v1.15 the fallback respects the provider.
    public static func defaultLabel(for provider: String) -> String {
        L10n.sessions.rowFallbackLabel(displayName(for: provider))
    }

    /// The `client_label` this app sends when it starts a managed session from
    /// the Sessions tab's New Local menu. It is stored by the helper and
    /// returned to every viewer, Mac and iPhone alike, so it stays English;
    /// `clientLabelDisplay` translates it where it is shown.
    public static func localStartClientLabel(for provider: String) -> String {
        "Local \(displayName(for: provider)) session"
    }

    /// The `client_label` sent for a session started in the in-app terminal
    /// window. An identifier rather than copy, and translated the same way.
    public static let inAppTerminalClientLabel = "in-app-terminal"

    /// A managed session's `client_label` as shown to the reader. The two labels
    /// this app writes itself are rendered in the reader's language; anything
    /// else — an iPhone's own device name, a label from another client — is the
    /// sender's text and is shown as written.
    public static func clientLabelDisplay(_ label: String, provider: String) -> String {
        if label == inAppTerminalClientLabel {
            return L10n.sessions.rowInAppTerminalLabel(displayName(for: provider))
        }
        if label == localStartClientLabel(for: provider) {
            return L10n.sessions.rowLocalLabel(displayName(for: provider))
        }
        return label
    }

    /// Row title for a managed session in the Mac Sessions tab.
    ///
    /// An empty label falls back to "<Provider> session". A label equal to the
    /// device name reads "<Provider> on <device>" rather than repeating the
    /// device twice ("CLI Pulse Helper · CLI Pulse Helper").
    public static func managedRowLabel(clientLabel: String?, deviceName: String?, provider: String) -> String {
        let label = clientLabel?.trimmingCharacters(in: .whitespaces) ?? ""
        let device = deviceName?.trimmingCharacters(in: .whitespaces) ?? ""
        let providerName = displayName(for: provider)
        if label.isEmpty { return L10n.sessions.rowFallbackLabel(providerName) }
        if !device.isEmpty && label.caseInsensitiveCompare(device) == .orderedSame {
            return L10n.sessions.rowLabelOnDevice(providerName, device)
        }
        return clientLabelDisplay(label, provider: provider)
    }

    /// Section header for the managed-sessions list. Pre-v1.15 the UI
    /// hardcoded `"Managed Claude sessions"`. With multi-CLI shipping,
    /// the static header drops the provider name (it's unknown until
    /// the user picks one in the New menu).
    public static var managedSectionHeader: String { L10n.sessions.managedSectionHeader }

    private static func normalize(_ provider: String) -> String {
        provider.trimmingCharacters(in: .whitespaces).lowercased()
    }
}
