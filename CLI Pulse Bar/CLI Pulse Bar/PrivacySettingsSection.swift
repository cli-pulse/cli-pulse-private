import SwiftUI
import CLIPulseCore

/// v1.19.1 — Privacy preferences section. Two toggles: a specific
/// "skip Claude Code cross-app keychain read" and a master "local-only
/// mode" that implies it. Sits above the main settings picker so it's
/// discoverable without digging into Advanced — same level as
/// SubscriptionSection / CompanionCLISection.
///
/// Motivation: macOS 26.x Keychain Agent regression makes the
/// "Always Allow / Allow" dialog unusable on at least one user's Mac
/// (see `feedback_keychain_agent_bug_macos26` memory). Defaults stay
/// OFF so users who already populated the keychain cache keep their
/// enrichment data.
struct PrivacySettingsSection: View {
    @ObservedObject private var settings = PrivacySettings.shared
    @EnvironmentObject var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "lock.shield")
                    .font(.system(size: 11))
                    .foregroundStyle(PulseTheme.accent)
                Text("Privacy")
                    .font(.system(size: 11, weight: .semibold))
                Spacer()
            }

            // v1.50 W-C. The promise the disclosure makes — "Settings › Privacy
            // changes it at any time" — is kept here, and it is the only way
            // back from "Not now". Shown to unauthenticated local-mode users
            // only: for a signed-in user the answer is implied by the account,
            // and a switch that reads as optional while cloud sync is running
            // would be a lie about which one is in charge.
            if !state.isAuthenticated && state.isLocalMode {
                Toggle(
                    isOn: Binding(
                        get: { state.localScanConsent == .granted },
                        set: { state.localScanConsent = $0 ? .granted : .declined }
                    )
                ) {
                    Text("Scan this Mac for CLI usage")
                        .font(.system(size: 11))
                }
                .toggleStyle(.switch)
                .controlSize(.small)

                Text("Reads the last 30 days of session logs under ~/.codex and ~/.claude, and asks the providers you use for live quota. Off means CLI Pulse reads nothing here.")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .padding(.leading, 2)
                    .padding(.bottom, 2)
                    .fixedSize(horizontal: false, vertical: true)

                Divider()
                    .padding(.vertical, 2)
            }

            Toggle(isOn: $settings.localOnlyMode) {
                Text("Local-only mode")
                    .font(.system(size: 11))
            }
            .toggleStyle(.switch)
            .controlSize(.small)

            Text("Skip all cross-app data sources. Usage data still works for files in your home directory.")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .padding(.leading, 2)
                .padding(.bottom, 2)

            Toggle(isOn: $settings.skipClaudeKeychain) {
                Text("Skip Claude Code keychain access")
                    .font(.system(size: 11))
            }
            .toggleStyle(.switch)
            .controlSize(.small)
            .disabled(settings.localOnlyMode)
            .padding(.leading, 16)
            .opacity(settings.localOnlyMode ? 0.6 : 1.0)

            Text(settings.localOnlyMode
                 ? "Forced ON by Local-only mode."
                 : "Stops CLI Pulse from reading the Claude Code OAuth credentials owned by other apps. Useful if you've hit a macOS keychain dialog that won't accept your login password.")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .padding(.leading, 18)
                .fixedSize(horizontal: false, vertical: true)

            Divider()
                .padding(.vertical, 2)

            // v1.34 R1d: opt-in hard block for managed Claude on an outdated
            // helper. Default OFF = warn-only (a banner tells the user the
            // session is on the Claude API, not their plan).
            Toggle(isOn: $settings.blockClaudeOnOutdatedHelper) {
                Text("Block managed Claude on outdated helper")
                    .font(.system(size: 11))
            }
            .toggleStyle(.switch)
            .controlSize(.small)

            Text("When the Companion CLI helper is too old to run Claude on your Max/Pro plan, prevent starting managed Claude sessions (which would silently use the Claude API). Off by default — you'll only see a warning.")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .padding(.leading, 2)
                .fixedSize(horizontal: false, vertical: true)

            Divider()
                .padding(.vertical, 2)

            // v1.45: anonymous install telemetry. Disabled rather than hidden
            // when local-only mode is on, so the master switch's effect is
            // visible instead of a control that silently does nothing.
            Toggle(isOn: $settings.anonymousTelemetryEnabled) {
                Text("Send anonymous install statistics")
                    .font(.system(size: 11))
            }
            .toggleStyle(.switch)
            .controlSize(.small)
            .disabled(settings.telemetrySuppressedByLocalOnly)

            Text(settings.telemetrySuppressedByLocalOnly
                 ? "Off — local-only mode covers this too."
                 : """
                   Two facts, with no account and nothing that identifies you \
                   or your machine: that CLI Pulse was installed, and whether \
                   it ever found a CLI to track. No file paths, project names, \
                   provider names, token counts or costs. The id is random and \
                   is deleted when you uninstall.
                   """)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .padding(.leading, 2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .background(Color.gray.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}
