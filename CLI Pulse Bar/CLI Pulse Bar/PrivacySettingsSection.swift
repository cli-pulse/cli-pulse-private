import SwiftUI
import Combine
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

    /// Bumped when the LoginItem helper finishes a cycle or reports on a
    /// switch change or on this app's request, so the line under the Claude
    /// keychain switches re-reads what it last reported.
    @State private var helperReportTick = 0

    /// v1.55: whether the LoginItem helper, a separate process that reads
    /// these switches from the app's copy (`HelperPrivacyInputs`), has said it
    /// skips the item too. Nil where this runtime has no helper.
    private var helperConfirmation: HelperClaudeKeychainConfirmation? {
        _ = helperReportTick
        guard state.runtimeEnvironment.capabilities.allowsHelperRegistration else { return nil }
        return HelperClaudeKeychainConfirmation.make(
            appSkips: settings.skipsClaudeKeychainOnItsOwn,
            helperStatus: HelperIPC.readStatus(),
            helperReport: UserDefaults(suiteName: HelperIPC.suiteName)
                .flatMap(HelperPrivacyInputs.loadHelperReport)
        )
    }

    /// v1.50 W-C: the scan itself — unauthenticated local mode only (see below).
    private var showsScanSwitch: Bool {
        !state.isAuthenticated && state.isLocalMode
    }

    /// v1.55: older logs — wherever the Mac scans, Demo mode aside.
    private var showsHistorySwitch: Bool {
        (state.isAuthenticated || state.isLocalMode) && !state.isDemoMode
    }

    /// v1.55: the way back from "Not now" for a signed-in Mac, which has no
    /// scan switch (see below) and no declined card on Overview.
    private var offersChoosingAgain: Bool {
        LocalCollectionPolicy.offersChoosingAgain(
            isAuthenticated: state.isAuthenticated,
            isDemoMode: state.isDemoMode,
            consent: state.localScanConsent
        )
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
            // changes it at any time" — is kept here, and in local mode it is
            // the way back from "Not now". Shown to unauthenticated local-mode
            // users only: for a signed-in user the answer is implied by the
            // account, and a switch that reads as optional while cloud sync is
            // running would be a lie about which one is in charge. A signed-in
            // "Not now" gets "Choose again…" below instead (v1.55).
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

            // v1.55: a signed-in Mac whose answer is "Not now". The switch above
            // is not shown to it, and signing in does not overturn the answer
            // (`LocalCollectionPolicy.allowsCollection`), so until 1.55 the only
            // way back was signing out. "Choose again…" reopens the first ask,
            // the whole disclosure with its three answers, in the popover.
            if offersChoosingAgain {
                Text(L10n.localScanConsent.declinedTitle)
                    .font(.system(size: 11))
                    .frame(maxWidth: .infinity, alignment: .leading)

                Text(L10n.localScanConsent.settingsDeclinedDetail)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .padding(.leading, 2)
                    .fixedSize(horizontal: false, vertical: true)

                Button(L10n.localScanConsent.chooseAgain) {
                    state.chooseLocalScanAgain()
                }
                .controlSize(.small)
                .padding(.bottom, 2)
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

            if showsScanSwitch || showsHistorySwitch || offersChoosingAgain {
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
                .fixedSize(horizontal: false, vertical: true)
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

            // v1.55: said only once the helper has said it. A helper from
            // before 1.55 keeps running after an in-place update and never
            // reads the switches, and that is the case this line exists for.
            if let helperConfirmation {
                Text(helperConfirmation == .confirmed
                     ? L10n.settings.claudeKeychainHelperConfirmed
                     : L10n.settings.claudeKeychainHelperUnconfirmed)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .padding(.leading, 18)
                    .fixedSize(horizontal: false, vertical: true)
            }

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
        // The helper records what it does with the item at the start of each
        // collecting cycle and posts this when the cycle's results are written.
        .onReceive(
            DistributedNotificationCenter.default()
                .publisher(for: HelperIPC.didSyncNotificationName)
                .receive(on: RunLoop.main)
        ) { _ in
            helperReportTick &+= 1
        }
        // And posts this when it reported on a switch change, or because this
        // app asked at launch, so the line follows a switch within a moment.
        .onReceive(
            DistributedNotificationCenter.default()
                .publisher(for: HelperPrivacyInputs.didReportNotificationName)
                .receive(on: RunLoop.main)
        ) { _ in
            helperReportTick &+= 1
        }
    }
}
