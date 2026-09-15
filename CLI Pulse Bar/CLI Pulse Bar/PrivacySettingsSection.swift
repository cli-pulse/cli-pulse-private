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
                Text(L10n.settings.privacy)
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
                    Text(L10n.localScanConsent.settingsToggle)
                        .font(.system(size: 11))
                }
                .toggleStyle(.switch)
                .controlSize(.small)

                Text(L10n.localScanConsent.settingsToggleDetail)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .padding(.leading, 2)
                    .padding(.bottom, 2)
                    .fixedSize(horizontal: false, vertical: true)

                Divider()
                    .padding(.vertical, 2)
            }

            Toggle(isOn: $settings.localOnlyMode) {
                Text(L10n.settings.localOnlyMode)
                    .font(.system(size: 11))
            }
            .toggleStyle(.switch)
            .controlSize(.small)

            Text(L10n.settings.localOnlyModeHint)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .padding(.leading, 2)
                .padding(.bottom, 2)

            Toggle(isOn: $settings.skipClaudeKeychain) {
                Text(L10n.settings.skipClaudeKeychain)
                    .font(.system(size: 11))
            }
            .toggleStyle(.switch)
            .controlSize(.small)
            .disabled(settings.localOnlyMode)
            .padding(.leading, 16)
            .opacity(settings.localOnlyMode ? 0.6 : 1.0)

            Text(settings.localOnlyMode
                 ? L10n.settings.skipClaudeKeychainForced
                 : L10n.settings.skipClaudeKeychainHint)
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
                Text(L10n.settings.blockClaudeOnOutdatedHelper)
                    .font(.system(size: 11))
            }
            .toggleStyle(.switch)
            .controlSize(.small)

            Text(L10n.settings.blockClaudeOnOutdatedHelperHint)
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
                Text(L10n.telemetry.toggle)
                    .font(.system(size: 11))
            }
            .toggleStyle(.switch)
            .controlSize(.small)
            .disabled(settings.telemetrySuppressedByLocalOnly)

            Text(settings.telemetrySuppressedByLocalOnly
                 ? L10n.telemetry.toggleLocalOnly
                 : L10n.telemetry.settingsBody)
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
