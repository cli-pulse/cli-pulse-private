import SwiftUI
import CLIPulseCore

private enum AgentSetupMode {
    case sync
    case local
}

/// Account-first onboarding V2. Routing and resumable progress live in
/// `AgentSetupState`; this view only renders the current state and dispatches
/// explicit user actions.
struct OnboardingWizardView: View {
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var authState: AuthState
    @EnvironmentObject private var providerState: ProviderState
    @Environment(\.openWindow) private var openWindow

    @Binding var setupState: AgentSetupState
    let onStateChange: (AgentSetupState) -> Void
    let onClose: () -> Void
    let onFinished: () -> Void

    @State private var candidates: [ProviderDiscoveryCandidate] = []
    @State private var isScanning = false
    @State private var selectedMode: AgentSetupMode?
    @State private var showingCompletion = false
    @State private var email = ""
    @State private var otpCode = ""
    @State private var password = ""
    @State private var usePasswordLogin = false

    private static let seededConfigsKey =
        "cli_pulse_agent_setup_seeded_provider_configs_v2"

    var body: some View {
        ZStack(alignment: .topTrailing) {
            VStack(spacing: 0) {
                stepIndicator
                    .padding(.top, 12)
                    .padding(.bottom, 8)

                Group {
                    if showingCompletion {
                        completionStep
                    } else {
                        stepContent
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.horizontal, 18)
                .padding(.bottom, 14)
                .animation(
                    .easeInOut(duration: 0.2),
                    value: currentStep
                )
            }

            Button {
                clearCredentialBuffers()
                onClose()
            } label: {
                Image(systemName: "xmark")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 30, height: 30)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
            .help(L10n.onboardingWizard.close)
            .accessibilityLabel(L10n.onboardingWizard.close)
            .padding(.top, 5)
            .padding(.trailing, 7)
        }
        .onAppear {
            if currentStep == .discovery {
                performDiscovery()
            }
        }
        .onChange(of: currentStep) { step in
            if step == .discovery {
                performDiscovery()
            }
            if step != .syncMode {
                showingCompletion = false
            }
        }
        .onChange(of: authState.isAuthenticated) { isAuthenticated in
            guard isAuthenticated else { return }
            clearCredentialBuffers()
            if currentStep == .syncMode {
                selectedMode = .sync
            }
        }
        .onDisappear {
            clearCredentialBuffers()
        }
    }

    @ViewBuilder
    private var stepContent: some View {
        switch currentStep {
        case .welcome:
            welcomeStep
        case .privacy:
            privacyStep
        case .discovery:
            discoveryStep
        case .review:
            reviewStep
        case .connection:
            connectionStep
        case .syncMode:
            modeStep
        case .completed:
            completionStep
        }
    }

    private var currentStep: AgentSetupStep {
        if case let .v2Onboarding(step) = setupState.route {
            return step
        }
        return setupState.progress?.step ?? .welcome
    }

    private var flowSteps: [AgentSetupStep] {
        switch setupState.progress?.origin {
        case .existingUserUpgrade, .explicitRerun:
            return [
                .discovery,
                .review,
                .connection,
                .syncMode,
            ]
        case .newUser, .none:
            return [
                .welcome,
                .privacy,
                .discovery,
                .review,
                .connection,
                .syncMode,
            ]
        }
    }

    private var stepIndicator: some View {
        HStack(spacing: 6) {
            ForEach(Array(flowSteps.enumerated()), id: \.element) {
                index, step in
                Capsule()
                    .fill(
                        step == currentStep
                            ? PulseTheme.accent
                            : index < currentStepIndex
                                ? PulseTheme.accent.opacity(0.55)
                                : Color.secondary.opacity(0.18)
                    )
                    .frame(
                        width: step == currentStep ? 20 : 7,
                        height: 7
                    )
                    .accessibilityHidden(true)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            L10n.onboardingWizard.stepProgress(
                current: currentStepIndex + 1,
                total: flowSteps.count,
                name: currentStepAccessibilityName
            )
        )
    }

    private var currentStepIndex: Int {
        flowSteps.firstIndex(of: currentStep)
            ?? max(flowSteps.count - 1, 0)
    }

    private var currentStepAccessibilityName: String {
        switch currentStep {
        case .welcome:
            return L10n.onboardingWizard.welcomeTitle
        case .privacy:
            return L10n.onboardingWizard.privacyTitle
        case .discovery:
            return L10n.onboardingWizard.discoveryTitle
        case .review:
            return L10n.onboardingWizard.reviewTitle
        case .connection:
            return L10n.onboardingWizard.connectionTitle
        case .syncMode:
            return L10n.onboardingWizard.modeTitle
        case .completed:
            return L10n.onboardingWizard.finishTitle
        }
    }

    // MARK: - Welcome

    private var welcomeStep: some View {
        VStack(spacing: 18) {
            Spacer()

            Image(systemName: "waveform.path.ecg")
                .font(.system(size: 42))
                .foregroundStyle(PulseTheme.accent)
                .accessibilityHidden(true)

            Text(L10n.onboardingWizard.welcomeTitle)
                .font(.title2.weight(.semibold))

            Text(L10n.onboardingWizard.welcomeSubtitle)
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 9) {
                setupValue(
                    icon: "gauge.with.dots.needle.67percent",
                    text: L10n.welcomeChoice.subtitle
                )
                setupValue(
                    icon: "person.2.badge.gearshape",
                    text: L10n.onboardingWizard.welcomeAccountsBody
                )
                setupValue(
                    icon: "lock.shield",
                    text: L10n.onboardingWizard.privacyKeysTitle
                )
            }
            .padding(.horizontal, 16)

            Spacer()

            VStack(spacing: 8) {
                Button {
                    mutateSetupState { $0.advance() }
                } label: {
                    Text(L10n.onboardingWizard.findAgents)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(PulseTheme.accent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)

                Button(L10n.onboardingWizard.setUpLater) {
                    onClose()
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Privacy

    private var privacyStep: some View {
        VStack(spacing: 12) {
            stepHeader(
                title: L10n.onboardingWizard.privacyTitle,
                subtitle: L10n.onboardingWizard.privacyBody
            )

            ScrollView {
                LazyVStack(spacing: 10) {
                    privacyCard(
                        icon: "key.fill",
                        color: .green,
                        title: L10n.onboardingWizard.privacyKeysTitle,
                        detail: L10n.onboardingWizard.privacyKeysDetail
                    )
                    privacyCard(
                        icon: "arrow.left.arrow.right.circle.fill",
                        color: .blue,
                        title: L10n.onboardingWizard.privacyDirectTitle,
                        detail: L10n.onboardingWizard.privacyDirectDetail
                    )
                    privacyCard(
                        icon: "doc.text.magnifyingglass",
                        color: .green,
                        title: L10n.onboardingWizard.privacyRawTitle,
                        detail: L10n.onboardingWizard.privacyRawDetail
                    )
                    privacyCard(
                        icon: "icloud.and.arrow.up.fill",
                        color: .blue,
                        title: L10n.onboardingWizard.privacyMetricsTitle,
                        detail: L10n.onboardingWizard.privacyMetricsDetail
                    )
                }
            }

            navigationBar {
                mutateSetupState { $0.advance() }
            }
        }
    }

    // MARK: - Discovery

    private var discoveryStep: some View {
        VStack(spacing: 12) {
            AgentDiscoveryStepView(
                options: accountOptions,
                selectedAccountIDs:
                    setupState.progress?.selectedAccountIDs ?? [],
                undetectedProviderCount: candidates.filter {
                    $0.status == .notFound
                }.count,
                isScanning: isScanning,
                onToggle: toggleAccount,
                onConnect: openAccountSettings,
                onRescan: performDiscovery
            )

            navigationBar {
                persistSeededProviderMetadataIfNeeded()
                mutateSetupState { $0.advance() }
            }
        }
    }

    // MARK: - Review

    private var reviewStep: some View {
        VStack(spacing: 12) {
            stepHeader(
                title: L10n.onboardingWizard.reviewTitle,
                subtitle: L10n.onboardingWizard.reviewSubtitle
            )

            if selectedOptions.isEmpty {
                emptyState(
                    icon: "checklist.unchecked",
                    title: L10n.onboardingWizard.noAccountsSelected
                )
            } else {
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(selectedOptions) { option in
                            ProviderAccountSetupCard(
                                option: option,
                                isSelected: true,
                                isReadOnly: true
                            )
                        }
                    }
                    .padding(.horizontal, 2)
                }
            }

            navigationBar {
                persistSeededProviderMetadataIfNeeded()
                mutateSetupState { $0.advance() }
            }
        }
    }

    // MARK: - Connection

    private var connectionStep: some View {
        VStack(spacing: 12) {
            stepHeader(
                title: L10n.onboardingWizard.connectionTitle,
                subtitle: L10n.onboardingWizard.connectionSubtitle
            )

            if selectedOptions.isEmpty {
                emptyState(
                    icon: "person.crop.circle.badge.questionmark",
                    title: L10n.onboardingWizard.noAccountsSelected
                )
            } else {
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(selectedOptions) { option in
                            VStack(spacing: 8) {
                                ProviderAccountSetupCard(
                                    option: option,
                                    isSelected: true,
                                    isReadOnly: true
                                )

                                if option.status != .connected {
                                    Button {
                                        openAccountSettings(option.id)
                                    } label: {
                                        Label(
                                            L10n.onboardingWizard
                                                .openAccountSettings,
                                            systemImage:
                                                "rectangle.portrait.and.arrow.right"
                                        )
                                        .frame(maxWidth: .infinity)
                                    }
                                    .buttonStyle(.bordered)
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 2)
                }

                Text(L10n.onboardingWizard.connectionOptional)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            navigationBar {
                mutateSetupState { $0.advance() }
            }
        }
    }

    // MARK: - Mode

    private var modeStep: some View {
        VStack(spacing: 12) {
            stepHeader(
                title: L10n.onboardingWizard.modeTitle,
                subtitle: L10n.onboardingWizard.modeSubtitle
            )

            VStack(spacing: 10) {
                modeOption(
                    mode: .sync,
                    icon: "icloud.and.arrow.up.fill",
                    color: .blue,
                    title: L10n.onboardingWizard.syncModeTitle,
                    body: L10n.onboardingWizard.syncModeBody
                )
                modeOption(
                    mode: .local,
                    icon: "desktopcomputer",
                    color: .green,
                    title: L10n.onboardingWizard.localOnlyTitle,
                    body: L10n.onboardingWizard.localOnlyBody
                )
            }

            if selectedMode == .sync {
                if authState.isAuthenticated {
                    Label(
                        L10n.onboardingWizard.signedInReady,
                        systemImage: "checkmark.circle.fill"
                    )
                    .font(.callout)
                    .foregroundStyle(.green)
                    .padding(.vertical, 8)
                } else {
                    syncSignInForm
                }
            }

            Spacer(minLength: 4)

            navigationBar(
                primaryDisabled:
                    selectedMode == nil
                    || (selectedMode == .sync
                        && !authState.isAuthenticated)
            ) {
                showingCompletion = true
            }
        }
    }

    @ViewBuilder
    private var syncSignInForm: some View {
        VStack(spacing: 8) {
            Text(L10n.onboardingWizard.signInForSync)
                .font(.caption)
                .foregroundStyle(.secondary)

            if state.otpSent {
                Text(L10n.onboardingWizard.codeSentTo(state.otpEmail))
                    .font(.caption)
                    .foregroundStyle(.green)

                TextField(
                    L10n.auth.codePlaceholder,
                    text: $otpCode
                )
                .textFieldStyle(.roundedBorder)
                .onSubmit(verifyOTP)

                Button(L10n.onboardingWizard.verify, action: verifyOTP)
                    .buttonStyle(.borderedProminent)
                    .disabled(
                        otpCode.trimmingCharacters(
                            in: .whitespacesAndNewlines
                        ).isEmpty
                    )

                Button(L10n.onboardingWizard.backToEmail) {
                    otpCode = ""
                    state.resetOTP()
                }
                .buttonStyle(.plain)
                .font(.caption)
            } else if usePasswordLogin {
                TextField(
                    L10n.login.emailPlaceholder,
                    text: $email
                )
                .textFieldStyle(.roundedBorder)
                .onSubmit(signInWithPassword)

                SecureField(
                    L10n.auth.passwordPlaceholder,
                    text: $password
                )
                .textFieldStyle(.roundedBorder)
                .onSubmit(signInWithPassword)

                Button(
                    L10n.auth.passwordSignIn,
                    action: signInWithPassword
                )
                .buttonStyle(.borderedProminent)
                .disabled(
                    !validEmail
                    || password.isEmpty
                    || state.isLoading
                )

                Button(L10n.auth.useEmailCode) {
                    password = ""
                    usePasswordLogin = false
                    state.lastError = nil
                }
                .buttonStyle(.plain)
                .font(.caption)
            } else {
                TextField(
                    L10n.login.emailPlaceholder,
                    text: $email
                )
                .textFieldStyle(.roundedBorder)
                .onSubmit(sendCode)

                Button(L10n.auth.sendCode, action: sendCode)
                    .buttonStyle(.borderedProminent)
                    .disabled(!validEmail || state.isLoading)

                Button(L10n.auth.usePassword) {
                    usePasswordLogin = true
                    state.lastError = nil
                }
                .buttonStyle(.plain)
                .font(.caption)
            }

            if let error = state.lastError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
            }

            if state.isLoading {
                ProgressView()
                    .controlSize(.small)
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.secondary.opacity(0.06))
        )
    }

    // MARK: - Completion

    private var completionStep: some View {
        VStack(spacing: 12) {
            stepHeader(
                title: L10n.onboardingWizard.finishTitle,
                subtitle: L10n.onboardingWizard.finishBody
            )

            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 34))
                .foregroundStyle(.green)
                .accessibilityHidden(true)

            if !selectedOptions.isEmpty {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(selectedOptions) { option in
                            ProviderAccountSetupCard(
                                option: option,
                                isSelected: true,
                                isReadOnly: true
                            )
                        }
                    }
                    .padding(.horizontal, 2)
                }
            } else {
                Text(L10n.onboardingWizard.noAccountsSelected)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxHeight: .infinity)
            }

            Text(
                selectedMode == .sync
                    ? L10n.onboardingWizard.finishSyncBody
                    : L10n.onboardingWizard.finishLocalBody
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)

            HStack(spacing: 12) {
                Button(L10n.onboardingWizard.back) {
                    showingCompletion = false
                }
                .buttonStyle(.bordered)

                Button {
                    finishSetup()
                } label: {
                    Text(L10n.onboardingWizard.done)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(PulseTheme.accent)
                .keyboardShortcut(.defaultAction)
            }
        }
    }

    // MARK: - Account assembly and persistence

    private var accountOptions: [AgentSetupAccountOption] {
        candidates.flatMap {
            candidate -> [AgentSetupAccountOption] in
            let accountIDs: [UUID]
            if candidate.accountIDs.isEmpty {
                guard candidate.status != .notFound,
                      let fallbackID = providerState.providerConfigs
                        .first(where: { $0.kind == candidate.kind })?
                        .accountID
                else {
                    return []
                }
                accountIDs = [fallbackID]
            } else {
                accountIDs = candidate.accountIDs
            }

            return accountIDs.map { accountID in
                let config = providerState.providerConfigs.first {
                    $0.accountID == accountID
                }
                let usage = providerState.providerAccounts.first {
                    $0.id == accountID
                }
                let status: ProviderDiscoveryStatus
                if config?.hasCredentials == true || usage != nil {
                    status = .connected
                } else if candidate.accountIDs.contains(accountID) {
                    status = .actionRequired
                } else {
                    status = candidate.status
                }

                return AgentSetupAccountOption(
                    id: accountID,
                    provider: candidate.kind,
                    accountLabel:
                        usage?.accountLabel
                        ?? config?.accountLabel
                        ?? L10n.onboardingWizard.defaultAccount,
                    planLabel:
                        usage?.planEvidence.displayValue
                        ?? config?.planOverride,
                    status: status,
                    signals: candidate.signals
                )
            }
        }
    }

    private var selectedOptions: [AgentSetupAccountOption] {
        let selectedIDs =
            setupState.progress?.selectedAccountIDs ?? []
        return accountOptions.filter { selectedIDs.contains($0.id) }
    }

    private func performDiscovery() {
        guard !isScanning else { return }
        isScanning = true

        Task { @MainActor in
            await Task.yield()
            let defaults = UserDefaults.standard
            let isSeeded = defaults.bool(
                forKey: Self.seededConfigsKey
            )
            let persistedData = defaults.data(
                forKey: ProviderAccountMigration.configsKey
            )
            let selectedIDs =
                setupState.progress?.selectedAccountIDs ?? []
            let visibleConfigs: [ProviderConfig]
            if persistedData == nil {
                visibleConfigs = []
            } else if isSeeded {
                visibleConfigs = providerState.providerConfigs.filter {
                    selectedIDs.contains($0.accountID)
                }
            } else {
                visibleConfigs = providerState.providerConfigs
            }

            let metadata = visibleConfigs.map(
                ProviderDiscoveryAccountMetadata.init(config:)
            )
            let connectedIDs = Set(
                providerState.providerConfigs
                    .filter(\.hasCredentials)
                    .map(\.accountID)
            ).union(
                providerState.providerAccounts.map(\.id)
            )
            let bookmarkIDs: Set<String> = Set(
                BookmarkManager.knownDirectories.compactMap { directory in
                    guard
                        ["codex", "claude", "gemini"]
                            .contains(directory.id),
                        BookmarkManager.shared.hasAccess(
                            to: directory.expandedPath
                        )
                    else {
                        return nil
                    }
                    return directory.id
                }
            )

            candidates = ProviderDiscoveryService().discover(
                context: ProviderDiscoveryContext(
                    accounts: metadata,
                    connectedAccountIDs: connectedIDs,
                    authorizedBookmarkIDs: bookmarkIDs
                )
            )
            isScanning = false
        }
    }

    private func toggleAccount(_ accountID: UUID) {
        mutateSetupState { state in
            if state.progress?.selectedAccountIDs.contains(accountID)
                == true {
                state.deselectAccount(accountID)
            } else {
                state.selectAccount(accountID)
            }
        }
        persistSeededProviderMetadataIfNeeded()
    }

    private func persistSeededProviderMetadataIfNeeded() {
        guard setupState.progress?.origin == .newUser else { return }
        let defaults = UserDefaults.standard
        let alreadySeeded = defaults.bool(
            forKey: Self.seededConfigsKey
        )
        let hasExistingData = defaults.data(
            forKey: ProviderAccountMigration.configsKey
        ) != nil
        guard alreadySeeded || !hasExistingData else { return }

        let selectedIDs =
            setupState.progress?.selectedAccountIDs ?? []
        var selectedConfigs = providerState.providerConfigs.filter {
            selectedIDs.contains($0.accountID)
        }
        for index in selectedConfigs.indices {
            selectedConfigs[index].isEnabled = false
        }

        if selectedConfigs.isEmpty {
            defaults.removeObject(
                forKey: ProviderAccountMigration.configsKey
            )
            defaults.removeObject(
                forKey: ProviderAccountMigration.schemaVersionKey
            )
        } else if let data = try? JSONEncoder().encode(selectedConfigs) {
            defaults.set(
                data,
                forKey: ProviderAccountMigration.configsKey
            )
            defaults.set(
                ProviderAccountMigration.currentSchemaVersion,
                forKey: ProviderAccountMigration.schemaVersionKey
            )
        }
        defaults.set(true, forKey: Self.seededConfigsKey)
    }

    @discardableResult
    private func applySelectedAccounts() -> Bool {
        let selectedIDs =
            setupState.progress?.selectedAccountIDs ?? []
        let candidateIDs = Set(accountOptions.map(\.id))
        let isNewUserFlow =
            setupState.progress?.origin == .newUser

        var configs = providerState.providerConfigs
        for index in configs.indices {
            if isNewUserFlow {
                configs[index].isEnabled =
                    selectedIDs.contains(configs[index].accountID)
            } else if candidateIDs.contains(configs[index].accountID) {
                configs[index].isEnabled =
                    selectedIDs.contains(configs[index].accountID)
            }
        }
        providerState.providerConfigs = configs
        // Completing the provider picker is the user's explicit authorization
        // decision, including the valid choice to select none.
        guard state.confirmProviderCollectionSelection() else {
            return false
        }
        UserDefaults.standard.removeObject(
            forKey: Self.seededConfigsKey
        )
        return true
    }

    private func openAccountSettings(_ accountID: UUID) {
        guard accountOptions.contains(
            where: { $0.id == accountID }
        ) else {
            return
        }
        providerState.editingProviderAccountID = accountID
        openWindow(id: "provider-config")
    }

    // MARK: - Actions and reusable chrome

    private func mutateSetupState(
        _ mutation: (inout AgentSetupState) -> Void
    ) {
        var updated = setupState
        mutation(&updated)
        setupState = updated
        onStateChange(updated)
    }

    private func finishSetup() {
        guard applySelectedAccounts() else {
            state.lastError =
                "Could not safely save the provider selection. Please retry."
            return
        }

        if selectedMode == .local {
            state.continueWithoutAccount()
        } else {
            state.isLocalMode = false
        }

        mutateSetupState {
            $0.complete()
        }
        clearCredentialBuffers()
        onFinished()
    }

    private var validEmail: Bool {
        !email.isEmpty && email.contains("@")
    }

    private func sendCode() {
        guard validEmail, !state.isLoading else { return }
        Task { await state.sendOTP(email: email) }
    }

    private func signInWithPassword() {
        guard
            validEmail,
            !password.isEmpty,
            !state.isLoading
        else {
            return
        }
        Task {
            await state.signInWithPassword(
                email: email,
                password: password
            )
        }
    }

    private func verifyOTP() {
        let code = otpCode.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !code.isEmpty else { return }
        Task { await state.verifyOTP(code: code) }
    }

    private func clearCredentialBuffers() {
        password = ""
        otpCode = ""
        usePasswordLogin = false
    }

    private func setupValue(
        icon: String,
        text: String
    ) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: icon)
                .foregroundStyle(PulseTheme.accent)
                .frame(width: 20)
                .accessibilityHidden(true)
            Text(text)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }

    private func stepHeader(
        title: String,
        subtitle: String
    ) -> some View {
        VStack(spacing: 5) {
            Text(title)
                .font(.title3.weight(.semibold))
            Text(subtitle)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func emptyState(
        icon: String,
        title: String
    ) -> some View {
        VStack(spacing: 9) {
            Image(systemName: icon)
                .font(.system(size: 28, weight: .medium))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(title)
                .font(.headline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }

    private func privacyCard(
        icon: String,
        color: Color,
        title: String,
        detail: String
    ) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(color)
                .frame(width: 24)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.secondary.opacity(0.06))
        )
        .accessibilityElement(children: .combine)
    }

    private func modeOption(
        mode: AgentSetupMode,
        icon: String,
        color: Color,
        title: String,
        body: String
    ) -> some View {
        Button {
            selectedMode = mode
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: icon)
                    .font(.title3)
                    .foregroundStyle(color)
                    .frame(width: 26)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.headline)
                        .foregroundStyle(.primary)
                    Text(body)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Image(
                    systemName:
                        selectedMode == mode
                            ? "checkmark.circle.fill"
                            : "circle"
                )
                .foregroundStyle(
                    selectedMode == mode
                        ? PulseTheme.accent
                        : .secondary
                )
            }
            .padding(11)
            .background(
                RoundedRectangle(cornerRadius: 11)
                    .fill(color.opacity(0.07))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 11)
                    .stroke(
                        selectedMode == mode
                            ? color.opacity(0.65)
                            : color.opacity(0.18),
                        lineWidth: selectedMode == mode ? 1.5 : 1
                    )
            )
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(
            selectedMode == mode ? .isSelected : []
        )
    }

    private func navigationBar(
        primaryDisabled: Bool = false,
        onPrimary: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 12) {
            if setupState.canMoveBackward {
                Button(L10n.onboardingWizard.back) {
                    mutateSetupState { $0.moveBackward() }
                }
                .buttonStyle(.bordered)
            } else {
                Button(L10n.onboardingWizard.back) {
                    onClose()
                }
                .buttonStyle(.bordered)
            }

            Button {
                onPrimary()
            } label: {
                Text(L10n.onboardingWizard.continue)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(PulseTheme.accent)
            .disabled(primaryDisabled)
            .keyboardShortcut(.defaultAction)
        }
    }
}

/// Multi-step onboarding wizard shown to new macOS users before authentication.
/// Steps: Welcome → Features → Privacy (v1.9.4) → Sign In → Pair Device (optional)
struct LegacyOnboardingWizardView: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var authState: AuthState
    @AppStorage("cli_pulse_onboarding_completed") private var onboardingCompleted = false
    @State private var step = 0
    @State private var email = ""
    @State private var otpCode = ""
    // v1.10.3 rejection fix: add password sign-in to the onboarding wizard.
    // macOS first-launch users are forced through this wizard (MenuBarView.swift:73),
    // and the ASC demo mailbox cannot receive OTP (clipulse.app has no MX record),
    // so OTP-only here was the actual blocker.
    @State private var password = ""
    // iter9 hotfix (2026-04-29): explicit two-mode picker for the email
    // sign-in form. Default `.emailCode` (single button "Send Verification
    // Code", label never changes); `.password` opt-in for App Store
    // reviewers. Mirrors `SettingsTab.loginSection` and `iOSLoginView`.
    @State private var usePasswordLogin = false

    var body: some View {
        // iter13 hotfix (2026-04-29): every step previously trapped the
        // user behind the wizard's flow buttons. iter9 added "Skip for
        // now" on step 3 and iter10 cleaned up the pair step, but
        // steps 0/1/2 still had no escape — a user who launched the
        // app, decided they didn't want to sign in, and just wanted the
        // menu-bar shell had to click through Welcome → Features →
        // Privacy → Sign In before they could even see the skip
        // button. The fix: a permanent close button overlaid in the
        // top-right that's visible on EVERY step. Setting
        // `onboardingCompleted = true` flips the @AppStorage flag so
        // MenuBarView swaps to the real UI; the flag persists, so
        // re-opening the menu bar later does NOT replay the wizard
        // (the user can manually re-trigger via the in-app "Reset
        // onboarding" path if one exists).
        ZStack(alignment: .topTrailing) {
            VStack(spacing: 0) {
                // Step indicator
                HStack(spacing: 6) {
                    ForEach(0..<5) { i in
                        Circle()
                            .fill(i <= step ? PulseTheme.accent : Color.gray.opacity(0.3))
                            .frame(width: 6, height: 6)
                    }
                }
                .padding(.top, 12)
                .padding(.bottom, 8)

                // Content
                Group {
                    switch step {
                    case 0: welcomeStep
                    case 1: featuresStep
                    case 2: privacyStep
                    case 3: signInStep
                    case 4: pairStep
                    default: welcomeStep
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .animation(.easeInOut(duration: 0.25), value: step)
            }

            // Global close button — always present, always reachable.
            // Uses `.plain` style + secondary tint so it doesn't draw
            // attention away from the step's primary CTA, but the
            // tap-target is wide enough (28×28) to hit reliably.
            //
            // v1.44 W1: dismissing the wizard now ENTERS LOCAL MODE and
            // lands on Overview with real numbers.
            //
            // iter16 (2026-04-29) routed this to `.settings` instead, and
            // its reasoning was right about the symptom — "the user would
            // see an empty 'No Data Yet' view as their first impression" —
            // but the cure was to route them AWAY from the product. That
            // choice is the measured shape of the funnel: 187 signups →
            // 67 devices, a 64% loss at exactly the step where we ask for
            // an account before showing anything.
            //
            // The empty-Overview problem was never that Overview is empty;
            // it is that nothing had turned local mode ON, so the refresh
            // loop never started. `continueWithoutAccount()` does all of
            // it (local mode + `.overview` + start loop + refresh now), so
            // the honest fix is one call. Sign-in stays reachable from
            // Settings → Connection.
            Button {
                state.continueWithoutAccount()
                onboardingCompleted = true
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(L10n.onboardingWizard.close)
            .accessibilityLabel(L10n.onboardingWizard.close)
            .padding(.top, 6)
            .padding(.trailing, 8)
        }
        .onChange(of: authState.isAuthenticated) { isAuth in
            if isAuth {
                // Always clear credential buffers on successful auth, regardless
                // of which step the user is currently viewing. Guards against
                // the case where the user clicks "Back" while a sign-in request
                // is still in flight — without the unconditional clear, those
                // buffers would retain the plaintext password/OTP code across
                // a later sign-out. (Gemini 3.1 Pro review 2026-04-23.)
                password = ""
                otpCode = ""
                usePasswordLogin = false
                if step == 3 {
                    step = 4
                }
            }
        }
    }

    // MARK: - Step 0: Welcome

    private var welcomeStep: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "waveform.path.ecg")
                .font(.system(size: 40))
                .foregroundStyle(PulseTheme.accent)

            Text(L10n.onboardingWizard.welcomeTitle)
                .font(.title2.weight(.semibold))

            Text(L10n.onboardingWizard.welcomeSubtitle)
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Spacer()

            Button {
                step = 1
            } label: {
                Text(L10n.onboardingWizard.getStarted)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(PulseTheme.accent)
            .controlSize(.large)
            .padding(.horizontal, 40)

            // v1.50 W-B: the same action the × in the corner performs, with a
            // name on it.
            //
            // v1.44 W1 already made the exit one click and put it on every step.
            // What it did not do was let anyone see it: the button is an
            // unlabeled glyph, styled `.plain` with a secondary tint, and its own
            // comment says that was deliberate — "so it doesn't draw attention
            // away from the step's primary CTA". A user who wants to try the app
            // without an account has to guess that the close box means "continue
            // without one" rather than "quit".
            //
            // So this is labeling, not architecture. Both controls call
            // `continueWithoutAccount()`; the × stays for people who reach for
            // it, and this is for everyone who would not.
            //
            // Deliberately secondary, not a second prominent button. Signing in
            // is still the recommended path — this stops being a hidden door
            // without becoming a nudge away from an account.
            VStack(spacing: 2) {
                Button {
                    state.continueWithoutAccount()
                    onboardingCompleted = true
                } label: {
                    Text(L10n.onboardingWizard.useLocally)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)

                Text(L10n.onboardingWizard.useLocallyHint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 40)
            .padding(.top, 8)
            .padding(.bottom, 20)
        }
        .padding()
    }

    // MARK: - Step 1: Features

    private var featuresStep: some View {
        VStack(spacing: 12) {
            Text(L10n.onboardingWizard.whatDoes)
                .font(.headline)
                .padding(.top, 12)

            ScrollView {
                VStack(spacing: 10) {
                    featureCard(icon: "chart.bar.fill", title: "Usage Tracking",
                                desc: "Real-time token usage across Claude, Codex, Gemini, and 14+ providers.")
                    featureCard(icon: "bell.badge.fill", title: "Smart Alerts",
                                desc: "Get notified when quotas run low, costs spike, or sessions fail.")
                    featureCard(icon: "desktopcomputer", title: "Multi-Device",
                                desc: "Monitor all your dev machines from the menu bar.")
                    featureCard(icon: "dollarsign.circle.fill", title: "Cost Estimates",
                                desc: "Track daily and weekly spend per provider.")
                }
                .padding(.horizontal, 16)
            }

            Spacer()

            HStack(spacing: 12) {
                Button(L10n.onboardingWizard.back) { step = 0 }
                    .buttonStyle(.bordered)

                Button {
                    step = 2
                } label: {
                    Text(L10n.onboardingWizard.continue)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(PulseTheme.accent)
            }
            .padding(.horizontal, 40)
            .padding(.bottom, 20)
        }
    }

    // MARK: - Step 2: Privacy (v1.9.4)

    private var privacyStep: some View {
        VStack(spacing: 12) {
            Text(L10n.onboardingWizard.privacyTitle)
                .font(.headline)
                .padding(.top, 12)

            Text(L10n.onboardingWizard.privacyBody)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)

            ScrollView {
                VStack(spacing: 10) {
                    onboardingPrivacyCard(
                        icon: "lock.fill",
                        color: .green,
                        title: L10n.onboardingWizard.privacyKeysTitle,
                        detail: L10n.onboardingWizard.privacyKeysDetail
                    )
                    onboardingPrivacyCard(
                        icon: "internaldrive.fill",
                        color: .green,
                        title: L10n.onboardingWizard.privacyLogsTitle,
                        detail: L10n.onboardingWizard.privacyLogsDetail
                    )
                    onboardingPrivacyCard(
                        icon: "icloud.and.arrow.up.fill",
                        color: .blue,
                        title: L10n.onboardingWizard.privacyMetricsTitle,
                        detail: L10n.onboardingWizard.privacyMetricsDetail
                    )
                }
                .padding(.horizontal, 16)
            }

            Spacer()

            HStack(spacing: 12) {
                Button(L10n.onboardingWizard.back) { step = 1 }
                    .buttonStyle(.bordered)

                Button {
                    step = 3
                } label: {
                    Text(L10n.onboardingWizard.continue)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(PulseTheme.accent)
            }
            .padding(.horizontal, 40)
            .padding(.bottom, 20)
        }
    }

    private func onboardingPrivacyCard(icon: String, color: Color, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 18))
                .foregroundStyle(color)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                Text(detail)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Step 3: Sign In

    private var signInStep: some View {
        VStack(spacing: 12) {
            Text(L10n.onboardingWizard.signInTitle)
                .font(.headline)
                .padding(.top, 12)

            // iter9 hotfix: copy no longer says "Create an account or
            // sign in" — there is no separate registration step. Supabase
            // `sendOTP` runs with `create_user: true`, so the first
            // OTP-verify auto-creates the account. Tell the user that
            // honestly instead of pretending there are two paths.
            Text(L10n.onboardingWizard.signInSubtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Spacer()

            // Three mutually-exclusive modes routed by `usePasswordLogin`
            // and `state.otpSent`. The button labels in each mode are
            // hard-coded — no semantic shape-shifting based on whether
            // adjacent fields are empty.
            if state.otpSent {
                otpVerifyForm
            } else if usePasswordLogin {
                passwordForm
            } else {
                emailCodeForm
            }

            if let error = state.lastError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            if state.isLoading {
                ProgressView()
                    .controlSize(.small)
            }

            Spacer()

            // iter10 hotfix (2026-04-29): step 3 was previously a hard
            // trap — the only button was "Back" (which loops to step 2)
            // and the wizard's `onboardingCompleted` flag was set ONLY
            // by step 4's "Skip for now" / "Done" buttons. Step 4 is
            // reachable only via the `.onChange(of: authState.isAuth-
            // enticated)` auto-advance, which fires only after the user
            // signs in. Net result: a user who didn't want to sign in
            // had no way out of the wizard short of force-quitting.
            //
            // Adding a "Skip for now" sibling here lets the user proceed
            // to the menu-bar shell unauthenticated.
            //
            // v1.44 W1: that hotfix's closing claim — "the Mac app's local
            // mode (`refreshLocal`) handles unauthenticated collectors, so
            // this is a graceful exit" — described a mode nothing had
            // switched on. Setting `onboardingCompleted` alone leaves
            // `isLocalMode == false` and no refresh loop running, so the
            // exit landed on a permanently empty Overview. It was a
            // less-obvious version of the same trap it set out to fix.
            // `continueWithoutAccount()` actually enters that mode.
            HStack(spacing: 12) {
                Button(L10n.onboardingWizard.back) { step = 2 }
                    .buttonStyle(.bordered)
                    .disabled(state.isLoading)

                Button(L10n.onboardingWizard.skip) {
                    state.continueWithoutAccount()
                    onboardingCompleted = true
                }
                .buttonStyle(.bordered)
                .disabled(state.isLoading)
            }
            .padding(.bottom, 20)
        }
        .padding(.horizontal, 20)
    }

    // MARK: - Sign-in sub-forms (iter9)

    private var emailCodeForm: some View {
        VStack(spacing: 8) {
            TextField("Email", text: $email)
                .textFieldStyle(.roundedBorder)
                .frame(width: 260)
                .onSubmit { sendCode() }

            Button {
                sendCode()
            } label: {
                Text(L10n.auth.sendCode)
                    .frame(width: 200)
            }
            .buttonStyle(.borderedProminent)
            .tint(PulseTheme.accent)
            .disabled(email.isEmpty || !email.contains("@") || state.isLoading)

            // Tiny disclosure for App Store reviewers — password is not
            // part of the regular user path on macOS either.
            Button {
                usePasswordLogin = true
                state.lastError = nil
            } label: {
                Text(L10n.auth.usePassword)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var passwordForm: some View {
        VStack(spacing: 8) {
            TextField("Email", text: $email)
                .textFieldStyle(.roundedBorder)
                .frame(width: 260)
                .onSubmit { signInWithPassword() }

            SecureField(L10n.auth.passwordPlaceholder, text: $password)
                .textFieldStyle(.roundedBorder)
                .frame(width: 260)
                .onSubmit { signInWithPassword() }

            Button {
                signInWithPassword()
            } label: {
                // Hard-coded "Sign In" — never flips to "Send Code".
                Text(L10n.auth.passwordSignIn)
                    .frame(width: 200)
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
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var otpVerifyForm: some View {
        VStack(spacing: 8) {
            Text(L10n.onboardingWizard.codeSentTo(state.otpEmail))
                .font(.caption)
                .foregroundStyle(.green)

            TextField(L10n.auth.codePlaceholder, text: $otpCode)
                .textFieldStyle(.roundedBorder)
                .frame(width: 200)

            Button {
                Task { await state.verifyOTP(code: otpCode) }
            } label: {
                Text(L10n.onboardingWizard.verify)
                    .frame(width: 200)
            }
            .buttonStyle(.borderedProminent)
            .tint(PulseTheme.accent)
            .disabled(otpCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

            Button(L10n.onboardingWizard.backToEmail) {
                otpCode = ""
                password = ""
                state.resetOTP()
            }
            .font(.caption)
        }
    }

    // MARK: - Submit handlers (iter9 — single-purpose, no flip logic)

    private func sendCode() {
        guard !email.isEmpty, email.contains("@"), !state.isLoading else { return }
        Task { await state.sendOTP(email: email) }
    }

    private func signInWithPassword() {
        guard !email.isEmpty, email.contains("@"), !password.isEmpty, !state.isLoading else { return }
        Task { await state.signInWithPassword(email: email, password: password) }
    }

    // MARK: - Step 4: All set
    //
    // iter10 hotfix (2026-04-29): this step previously read "Pair Your
    // First Device" and showed three `pip install cli-pulse-helper`
    // commands as if helper pairing was a required setup step. That
    // contradicts the iter9 product reality — sync is account-scoped:
    // the Mac app uploads usage data to the user's Supabase account
    // automatically, and any signed-in iOS / Watch device fetches it
    // back without manual pairing. The helper daemon is now an opt-in
    // enhancement (Remote Approvals' permission-prompt forwarding,
    // headless server scenarios), NOT a basic-sync prerequisite. The
    // step's new copy reflects that — and points to Settings for users
    // who DO want the optional helper.

    private var pairStep: some View {
        VStack(spacing: 12) {
            Text(L10n.onboardingWizard.allSetTitle)
                .font(.headline)
                .padding(.top, 12)

            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 30))
                .foregroundStyle(.green)

            Text(L10n.onboardingWizard.allSetBody)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 20)

            // Optional-helper hint as a low-key footnote. Don't bury it
            // (some users genuinely want headless / Remote-Approvals
            // setups) but don't lead with it either.
            Text(L10n.onboardingWizard.helperHint)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 20)
                .padding(.top, 4)

            Spacer()

            Button {
                onboardingCompleted = true
            } label: {
                Text(L10n.onboardingWizard.done)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(PulseTheme.accent)
            .padding(.horizontal, 40)
            .padding(.bottom, 20)
        }
    }

    // MARK: - Helpers

    private func featureCard(icon: String, title: String, desc: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(PulseTheme.accent)
                .frame(width: 32)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(desc)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .padding(10)
        .background(Color(nsColor: .controlBackgroundColor))
        .cornerRadius(8)
    }

    private func setupStep(_ number: Int, _ text: String) -> some View {
        HStack(spacing: 8) {
            Text("\(number)")
                .font(.caption.weight(.bold))
                .foregroundStyle(.white)
                .frame(width: 18, height: 18)
                .background(PulseTheme.accent)
                .clipShape(Circle())

            Text(text)
                .font(.caption)
                .foregroundStyle(.primary)
        }
    }
}
