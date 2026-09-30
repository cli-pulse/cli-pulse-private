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

    /// v1.50 W-C: the scan itself — unauthenticated local mode only (see below).
    private var showsScanSwitch: Bool {
        !state.isAuthenticated && state.isLocalMode
    }

    /// v1.55: older logs — wherever the Mac scans, Demo mode aside.
    private var showsHistorySwitch: Bool {
        (state.isAuthenticated || state.isLocalMode) && !state.isDemoMode
    }

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
            if showsScanSwitch {
                Toggle(
                    isOn: Binding(
                        get: { state.localScanConsent == .granted },
                        set: { state.localScanConsent = $0 ? .granted : .declined }
                    )
                ) {
                    Text(L10n.localScanConsent.settingsToggle)
                        .font(.system(size: 11))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .toggleStyle(.switch)
                .controlSize(.small)

                Text(L10n.localScanConsent.settingsToggleDetail)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .padding(.leading, 2)
                    .padding(.bottom, 2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // v1.55: disclosure v2's own answer — up to a year of older logs,
            // read once. Shown wherever the Mac scans (signed in, or local mode),
            // because unlike the switch above it is a real choice for a signed-in
            // user too: signing in implies the 30-day scan, never the year. Not
            // in Demo mode, which reads nothing and is what screenshots show.
            //
            // Disabled, not hidden, while the scan itself is off: the switch
            // above says "Older logs have a switch of their own", and it should
            // be there to be seen. Turning this off stops further reads; it does
            // not delete history already built, and its detail says so.
            if showsHistorySwitch {
                let scanning = LocalCollectionPolicy.allowsCollection(
                    isAuthenticated: state.isAuthenticated,
                    consent: state.localScanConsent
                )
                Toggle(
                    isOn: Binding(
                        get: { scanning && state.localScanConsentV2 == .granted },
                        set: { on in
                            state.localScanConsentV2 = on ? .granted : .declined
                            // The backfill runs after a successful scan, so a
                            // yes shows its history on the next refresh rather
                            // than whenever the timer next fires.
                            if on { state.requestRefresh() }
                        }
                    )
                ) {
                    Text(L10n.localScanConsent.historyToggle)
                        .font(.system(size: 11))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .toggleStyle(.switch)
                .controlSize(.small)
                .disabled(!scanning)

                Text(L10n.localScanConsent.historyToggleDetail)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .padding(.leading, 2)
                    .padding(.bottom, 2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if showsScanSwitch || showsHistorySwitch {
                Divider()
                    .padding(.vertical, 2)
            }

            Toggle(isOn: $settings.localOnlyMode) {
                Text(L10n.settings.localOnlyMode)
                    .font(.system(size: 11))
                    .frame(maxWidth: .infinity, alignment: .leading)
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
                    .frame(maxWidth: .infinity, alignment: .leading)
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
                    .frame(maxWidth: .infinity, alignment: .leading)
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
                    .frame(maxWidth: .infinity, alignment: .leading)
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
