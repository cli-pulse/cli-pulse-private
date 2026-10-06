import SwiftUI
import ServiceManagement
import StoreKit
import CLIPulseCore

struct SettingsTab: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var authState: AuthState
    let canRerunAgentSetup: Bool
    let onRerunAgentSetup: () -> Void
    /// Observed so a language switch redraws this tab in place, keeping the
    /// @State below: typed sign-in details and the chosen section. Only the
    /// content under it is rebuilt (see `body`).
    @ObservedObject private var localeOverride = LocaleOverrideStore.shared
    @State private var email = ""
    @State private var otpCode = ""
    @State private var password = ""
    @State private var usePasswordLogin = false
    @State private var launchAtLogin = false
    @State private var helperEnabled = false
    @State private var settingsSection: SettingsSection = .general
    /// Settings › Advanced drawn without the section picker (no paired
    /// account): whether it is open. Closed at first, as the picker opens on
    /// General.
    @State private var advancedExpanded = false
    #if CLIPULSE_QA_RENDER
    @Environment(\.qaRenderViewState) private var qaRenderViewState
    #endif
    // Delete-account state moved to DangerZoneSection.swift (v1.10 P2-2)
    // showGitTrackingConsent state moved to AdvancedSection (v1.10 P2-2 slice 6)
    // alertThresholds state moved to GeneralSection.swift (v1.10 P2-2 slice 5)

    enum SettingsSection: String, CaseIterable {
        case general = "General"
        case display = "Display"
        case providers = "Providers"
        case advanced = "Advanced"

        var label: String {
            switch self {
            case .general: return L10n.settings.general
            case .display: return L10n.settings.display
            case .providers: return L10n.settings.providers
            case .advanced: return L10n.settings.advanced
            }
        }
    }

    var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 12) {
                Text(L10n.settings.title)
                    .font(.system(size: 14, weight: .bold))

                if canRerunAgentSetup {
                    agentSetupRerunCard
                }

                if authState.isAuthenticated {
                    authenticatedSection
                } else {
                    loginSection
                    signedOutSections
                }
            }
            .padding(12)
            // The sections below (GeneralSection, PairingSection, …) take no
            // input that changes with the language, so SwiftUI would keep their
            // old bodies. Keying rebuilds them, and resets their own transient
            // state (an expanded row, an open confirmation) the way switching
            // tabs does. This view's @State lives above the key and survives,
            // so the fields bound to it keep what was typed.
            .languageKeyed(localeOverride.override)
        }
        #if CLIPULSE_QA_RENDER
        .onAppear(perform: applyQARenderViewState)
        #endif
    }

    #if CLIPULSE_QA_RENDER
    /// QA build only: open on the section and sign-in mode the offscreen
    /// renderer asks for, as a user would by clicking.
    private func applyQARenderViewState() {
        guard let qaRenderViewState else { return }
        if let raw = qaRenderViewState.settingsSection,
           let section = SettingsSection(rawValue: raw) {
            settingsSection = section
            advancedExpanded = section == .advanced
        }
        usePasswordLogin = qaRenderViewState.usePasswordLogin
    }
    #endif

    private var agentSetupRerunCard: some View {
        Button(action: onRerunAgentSetup) {
            HStack(spacing: 7) {
                Image(systemName: "arrow.clockwise.circle")
                    .font(.system(size: 11))
                    .foregroundStyle(PulseTheme.accent)
                    .frame(width: 18)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.providers.rerunAgentSetup)
                        .font(.system(
                            size: 10,
                            weight: .semibold
                        ))
                    Text(L10n.providers.rerunAgentSetupHint)
                        .font(.system(size: 8))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                }

                Spacer(minLength: 4)

                Image(systemName: "chevron.right")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
            .padding(8)
            .contentShape(Rectangle())
            .background(PulseTheme.cardBackground.opacity(0.3))
            .clipShape(RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .accessibilityHint(L10n.providers.rerunAgentSetupHint)
    }

    // MARK: - Login

    private var loginSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: L10n.settings.signIn, icon: "person.circle")

            if usePasswordLogin {
                // Password sign-in mode
                TextField(L10n.settings.email, text: $email)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11))

                SecureField(L10n.auth.passwordLabel, text: $password)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11))

                Button {
                    Task { await state.signInWithPassword(email: email, password: password) }
                } label: {
                    HStack {
                        if state.isLoading { ProgressView().controlSize(.small) }
                        Text(L10n.auth.passwordSignIn)
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
                .tint(PulseTheme.accent)
                .disabled(email.isEmpty || !email.contains("@") || password.isEmpty || state.isLoading)

                Button {
                    usePasswordLogin = false
                    password = ""
                    state.lastError = nil
                } label: {
                    Text(L10n.auth.useEmailCode)
                        .font(.system(size: 10))
                }
            } else if state.otpSent {
                Text(L10n.auth.codeSentTo(state.otpEmail))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)

                TextField(L10n.auth.codePlaceholder, text: $otpCode)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 14, weight: .semibold, design: .monospaced))

                Button {
                    Task { await state.verifyOTP(code: otpCode) }
                } label: {
                    HStack {
                        if state.isLoading { ProgressView().controlSize(.small) }
                        Text(L10n.auth.verifyCode)
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
                .tint(PulseTheme.accent)
                .disabled(otpCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || state.isLoading)

                Button { otpCode = ""; state.resetOTP() } label: {
                    Text(L10n.auth.backToEmail).font(.system(size: 10))
                }
            } else {
                TextField(L10n.settings.email, text: $email)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11))

                Button {
                    Task { await state.sendOTP(email: email) }
                } label: {
                    HStack {
                        if state.isLoading { ProgressView().controlSize(.small) }
                        Text(L10n.auth.sendCode)
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
                .tint(PulseTheme.accent)
                .disabled(email.isEmpty || !email.contains("@") || state.isLoading)

                Button {
                    usePasswordLogin = true
                    state.lastError = nil
                } label: {
                    Text(L10n.auth.usePassword)
                        .font(.system(size: 10))
                }
            }

            if let error = state.lastError {
                Text(error)
                    .font(.system(size: 10))
                    .foregroundStyle(.red)
            }

            // iter14 hotfix (2026-04-29): pre-iter14 the only way out
            // of this signed-out Settings panel was to sign in. After
            // delete-account or sign-out, users complained they were
            // "trapped" on a Sign-In form with no escape.
            //
            // iter17 (2026-04-29): the button now calls
            // `state.continueWithoutAccount()` which actually flips
            // the app into local mode (`isLocalMode = true`,
            // `selectedTab = .overview`, and triggers a refresh so
            // collector data appears immediately). The old version
            // only mutated `selectedTab` — refresh still bailed at
            // the `!isAuthenticated` gate, so users saw an empty
            // dashboard. Copy updated to "Use local mode" to match
            // the new semantics.
            Divider()
                .padding(.vertical, 2)
            Button {
                state.continueWithoutAccount()
            } label: {
                Label(L10n.auth.useLocalMode, systemImage: "arrow.right")
                    .font(.system(size: 11))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            Text(L10n.auth.useLocalModeHint)
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
        }
    }

    // MARK: - Sections that depend on the account

    /// Which of the sections below are shown, decided in one place for the
    /// signed-in and the local-mode branch (`SettingsAccountSections`).
    private var accountSections: SettingsAccountSections {
        SettingsAccountSections(
            isAuthenticated: authState.isAuthenticated,
            isPaired: authState.isPaired,
            isLocalMode: state.isLocalMode,
            // The note that names Settings › Companion CLI needs the same
            // capability to appear at all (`HelperInstaller.externalActionsAllowed`).
            runtimeOffersCompanionCLI: state.runtimeEnvironment.capabilities.allowsHelperManifestRefresh,
            // Background sync is in Advanced, and is all a signed-out Mac's
            // Advanced holds (`AdvancedSection`'s own gate).
            runtimeOffersBackgroundSync: state.runtimeEnvironment.capabilities.allowsHelperRegistration
        )
    }

    // MARK: - Signed out, and local mode

    /// Under the sign-in form, signed out and in local mode alike: neither
    /// reaches `authenticatedSection`.
    ///
    /// v1.55: Settings › Companion CLI and Settings › Privacy for a Mac in
    /// local mode. Both are named on screens a local-mode user sees: the first
    /// ask and `telemetry.change_later` send them to Settings › Privacy ("you
    /// can change this any time"), where the scan switch is
    /// (`PrivacySettingsSection.showsScanSwitch`, local mode only), and the
    /// note under the answer (`CompanionNotCoveredNote`) sends them to
    /// Settings › Companion CLI to update or uninstall a Companion that
    /// ignores it. Before 1.55 neither section rendered here, so both
    /// directions led nowhere. Outside local mode neither is shown.
    ///
    /// v1.56: the Developer ID updater and Settings › Advanced, in local mode
    /// and outside it. A signed-out Developer ID Mac was never offered an
    /// update in the app, and "Paused: signed out", which 1.55's notes said
    /// Settings › Advanced shows, could not be seen while it was true.
    private var signedOutSections: some View {
        VStack(alignment: .leading, spacing: 12) {
            if accountSections.companionCLI {
                Divider()
                CompanionCLISection(installer: state.helperInstaller)
            }

            #if DEVID_BUILD
            Divider()
            appUpdaterSection
            #endif

            if accountSections.privacy {
                Divider()
                PrivacySettingsSection()
            }

            advancedWithoutPicker
        }
    }

    // MARK: - Sections in both branches

    #if DEVID_BUILD
    /// v1.19: the Developer ID DMG channel's updater, only in DEVID builds:
    /// App Store users get updates from the App Store. The section also shows
    /// a banner reminding beta users to turn off App Store automatic updates,
    /// so the App Store version does not silently overwrite the beta.
    ///
    /// v1.56: drawn in both branches with no account gate. It is the only
    /// place this build shows an available update and installs it, and its
    /// manifest, download and verification do not depend on the account
    /// (`SettingsAccountSections`). The popover's focus hook already fetched
    /// the manifest daily whatever the account (`MenuBarView`), so drawing
    /// this signed out adds no request.
    private var appUpdaterSection: some View {
        AppUpdaterSection(
            updater: state.appUpdater,
            permMigration: state.permissionMigrationChecker
        )
    }
    #endif

    /// v1.56: Settings › Advanced where there is no section picker, which
    /// needs a paired account: signed in without one, in local mode, and
    /// signed out. A disclosure named like the picker's segment, so "Settings
    /// › Advanced" is something to click here too, holding what acts on this
    /// Mac alone (`SettingsAccountSections.Advanced`). Nothing for a paired
    /// account, whose Advanced is the picker's.
    @ViewBuilder
    private var advancedWithoutPicker: some View {
        if let content = accountSections.advanced, content != .full {
            Divider()
            DisclosureGroup(isExpanded: $advancedExpanded) {
                AdvancedSection(
                    launchAtLogin: $launchAtLogin,
                    helperEnabled: $helperEnabled,
                    content: content
                )
                .padding(.top, 6)
            } label: {
                // The whole row opens it, not just the chevron.
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        advancedExpanded.toggle()
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "slider.horizontal.3")
                            .font(.system(size: 11))
                            .foregroundStyle(PulseTheme.accent)
                            .accessibilityHidden(true)
                        Text(L10n.settings.advanced)
                            .font(.system(size: 11, weight: .semibold))
                        Spacer()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - Authenticated

    private var authenticatedSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            AccountCardView()

            // `isPaired` is the ACCOUNT's flag, true while any of its devices is
            // paired. This Mac may still need pairing — its own device removed,
            // or never paired here — and then it needs the pairing flow as well
            // as the settings of a paired account (`ThisMacPairing`).
            if authState.showsPairingFlow {
                Divider()
                PairingSection(helperEnabled: $helperEnabled)
            }

            // v1.55: each section below is shown by `accountSections`. Companion
            // CLI and Privacy are shown whether or not the account is paired: a
            // signed-in Mac that has not set up cloud sync still scans, and is
            // asked about older logs, and "Choose again…" and the older-logs
            // switch are in Privacy. Before 1.55 both were inside the paired
            // block. The paired account's own sections keep their order around
            // them. v1.56: so do the Developer ID updater and, without the
            // picker, Settings › Advanced.
            if accountSections.pairedAccountSettings {
                Divider()

                SubscriptionSection()
            }

            if accountSections.companionCLI {
                // v1.16: Companion CLI Helper installer surface, right above
                // the section picker so it's discoverable without digging into
                // Advanced. Renders nothing on iOS / Watch builds —
                // HelperInstaller is macOS-only.
                Divider()
                CompanionCLISection(installer: state.helperInstaller)
            }

            // The Developer ID updater, whether or not the account is paired
            // (`appUpdaterSection`).
            #if DEVID_BUILD
            Divider()
            appUpdaterSection
            #endif

            if accountSections.privacy {
                // v1.19.1: in-app privacy toggles (skip Claude Code
                // cross-app keychain read + master local-only mode).
                // Cross-channel — visible to MAS and DEVID builds alike
                // since the underlying keychain bug affects both.
                Divider()
                PrivacySettingsSection()
            }

            if accountSections.pairedAccountSettings {
                // Remote control: view lives in CLIPulseCore (no pbxproj entry).
                // M3 dark-ship — the card is not rendered at all when the
                // build does not offer the feature.
                if RemoteControlFeature.isAvailable() {
                    LANRemoteControlSection(agent: state.lanAgent)
                }

                Divider()

                // Section picker. Titled for VoiceOver only (`.labelsHidden()`).
                Picker(L10n.settings.title, selection: $settingsSection) {
                    ForEach(SettingsSection.allCases, id: \.self) { section in
                        Text(section.label)
                    }
                }
                .pickerStyle(.segmented)
                .controlSize(.small)
                .labelsHidden()

                switch settingsSection {
                case .general:
                    GeneralSection()
                case .display:
                    DisplaySection()
                case .providers:
                    ProviderSettingsSection()
                case .advanced:
                    AdvancedSection(
                        launchAtLogin: $launchAtLogin,
                        helperEnabled: $helperEnabled,
                        content: .full
                    )
                }
            }

            // Without a paired account: Advanced without the picker.
            advancedWithoutPicker

            Divider()
            DangerZoneSection()
        }
        // Between refreshes the helper may have written a new status, or the
        // pairing may have changed; opening Settings is when that must be right.
        .onAppear { state.refreshThisMacPairing() }
    }

    // MARK: - Pairing


    // PairingSection extracted to PairingSection.swift (v1.10 P2-2 slice 4).
    // HowItWorksCard extracted to HowItWorksCard.swift (v1.10 P2-2 slice 2).
    // AccountCardView extracted to AccountCardView.swift (v1.10 P2-2 slice 1).

    // setupStepsView, modeIndicator, copyButton, pairAndStartNativeHelper,
    // pairingInProgress/nativePairingError state all moved to PairingSection.swift
    // (v1.10 P2-2 slice 4). `setupStep<Content>` was unused dead code, deleted.

    // AccountCardView extracted to AccountCardView.swift (v1.10 P2-2)

    // SubscriptionSection extracted to SubscriptionSection.swift (v1.10 P2-2 slice 3)


}
