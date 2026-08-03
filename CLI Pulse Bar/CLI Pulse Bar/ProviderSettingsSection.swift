import SwiftUI
import CLIPulseCore

/// v1.10 P2-2 slice 8: extracted from SettingsTab.swift (pre-extraction
/// `providerSettingsSection` + `providerSettingsRow`). Per-provider
/// source/credentials display with a "gear" button to open the
/// provider-config window.
struct ProviderSettingsSection: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var providerState: ProviderState
    @Environment(\.openWindow) private var openWindow
    @State private var expandedKinds: Set<ProviderKind> = []
    @State private var accountPendingRemoval: ProviderConfig?

    /// Providers that the tier-migration auto-disabled. Read once per render
    /// from UserDefaults so the lock badge stays in sync even when the UI
    /// re-renders after the user re-enables via the gear → Save flow.
    private var disabledByTier: Set<ProviderKind> { AppState.providersDisabledByTier() }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(
                title: L10n.providers.accountConfiguration,
                icon: "person.2.badge.gearshape"
            )

            Text(L10n.providers.configureHint)
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)

            ForEach(orderedProviderKinds, id: \.self) { kind in
                providerGroup(kind)
            }
        }
        .onAppear {
            guard expandedKinds.isEmpty else { return }
            let configuredKinds = Set(
                providerState.providerConfigs.compactMap { config in
                    let hasLabel =
                        !(config.accountLabel?
                            .trimmingCharacters(
                                in: .whitespacesAndNewlines
                            ).isEmpty ?? true)
                    return config.hasCredentials
                        || hasLabel
                        || providerState.configs(for: config.kind).count > 1
                        ? config.kind
                        : nil
                }
            )
            expandedKinds = configuredKinds.isEmpty
                ? [.codex, .claude, .gemini]
                : configuredKinds
        }
        .alert(item: $accountPendingRemoval) { config in
            Alert(
                title: Text(
                    L10n.providers.removeAccountTitle(
                        config.kind.rawValue,
                        accountDisplayLabel(config)
                    )
                ),
                message: Text(
                    L10n.providers.removeAccountMessage
                ),
                primaryButton: .destructive(
                    Text(L10n.providers.removeAccount)
                ) {
                    _ = state.removeProviderAccount(
                        config.accountID
                    )
                },
                secondaryButton: .cancel()
            )
        }
    }

    private var orderedProviderKinds: [ProviderKind] {
        let caseOrder = Dictionary(
            uniqueKeysWithValues:
                ProviderKind.allCases.enumerated().map {
                    ($0.element, $0.offset)
                }
        )
        return ProviderKind.allCases.sorted { lhs, rhs in
            let lhsSort =
                providerState.configs(for: lhs)
                    .map(\.sortOrder).min()
                ?? Int.max
            let rhsSort =
                providerState.configs(for: rhs)
                    .map(\.sortOrder).min()
                ?? Int.max
            if lhsSort != rhsSort {
                return lhsSort < rhsSort
            }
            return (caseOrder[lhs] ?? Int.max)
                < (caseOrder[rhs] ?? Int.max)
        }
    }

    private func providerGroup(
        _ kind: ProviderKind
    ) -> some View {
        let configs = providerState.configs(for: kind)
        return DisclosureGroup(
            isExpanded: Binding(
                get: { expandedKinds.contains(kind) },
                set: { isExpanded in
                    if isExpanded {
                        expandedKinds.insert(kind)
                    } else {
                        expandedKinds.remove(kind)
                    }
                }
            )
        ) {
            VStack(spacing: 6) {
                if configs.isEmpty {
                    Text(L10n.providers.noAccountsConfigured)
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                        .frame(
                            maxWidth: .infinity,
                            alignment: .leading
                        )
                        .padding(.vertical, 4)
                } else {
                    ForEach(configs) { config in
                        accountRow(config)
                    }
                }

                Button {
                    let accountID = state.addProviderAccount(
                        kind: kind
                    )
                    providerState.editingProviderAccountID =
                        accountID
                    expandedKinds.insert(kind)
                    NSApp.activate(ignoringOtherApps: true)
                    openWindow(id: "provider-config")
                } label: {
                    Label(
                        L10n.providers.addAccount,
                        systemImage: "plus.circle"
                    )
                    .font(.system(size: 9, weight: .medium))
                    .frame(
                        maxWidth: .infinity,
                        alignment: .leading
                    )
                }
                .buttonStyle(.plain)
                .foregroundStyle(PulseTheme.accent)
            }
            .padding(.top, 6)
            .padding(.leading, 6)
        } label: {
            HStack(spacing: 7) {
                Image(systemName: kind.iconName)
                    .font(.system(size: 11))
                    .foregroundStyle(
                        PulseTheme.providerColor(kind.rawValue)
                    )
                    .frame(width: 18)
                    .accessibilityHidden(true)
                Text(kind.rawValue)
                    .font(.system(size: 10, weight: .semibold))
                Spacer()
                Text(L10n.providers.accountsCount(configs.count))
                    .font(.system(size: 8, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(Color.secondary.opacity(0.1))
                    .clipShape(Capsule())
            }
        }
        .padding(8)
        .background(PulseTheme.cardBackground.opacity(0.3))
        .clipShape(RoundedRectangle(cornerRadius: 7))
    }

    private func accountRow(
        _ config: ProviderConfig
    ) -> some View {
        let usage = providerState.providerAccounts.first {
            $0.id == config.accountID
        }
        let isConnected = accountIsConnected(
            config,
            usage: usage
        )
        let isLockedByTier =
            !config.isEnabled
            && disabledByTier.contains(config.kind)

        return HStack(spacing: 7) {
            Toggle(
                "",
                isOn: Binding(
                    get: { config.isEnabled },
                    set: { newValue in
                        state.setProviderAccountEnabled(
                            config.accountID,
                            isEnabled: newValue
                        )
                    }
                )
            )
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.mini)
            .accessibilityLabel(
                L10n.providers.monitorAccount(
                    accountDisplayLabel(config)
                )
            )

            VStack(alignment: .leading, spacing: 2) {
                Text(accountDisplayLabel(config))
                    .font(.system(size: 10, weight: .medium))
                    .lineLimit(1)

                HStack(spacing: 4) {
                    Text(
                        usage?.planEvidence.displayValue
                            ?? config.planOverride
                            ?? L10n.providers.planUnconfirmed
                    )
                    .font(.system(size: 8))
                    .foregroundStyle(.secondary)

                    Text(
                        isConnected
                            ? L10n.providers.connected
                            : L10n.providers.needsReconnect
                    )
                    .font(.system(size: 7, weight: .medium))
                    .foregroundStyle(
                        isConnected ? .green : .orange
                    )

                    if isLockedByTier {
                        Text(L10n.providers.limitedFree)
                            .font(.system(size: 7, weight: .medium))
                            .foregroundStyle(.orange)
                    }
                }
            }

            Spacer(minLength: 4)

            Button {
                providerState.editingProviderAccountID =
                    config.accountID
                NSApp.activate(ignoringOtherApps: true)
                openWindow(id: "provider-config")
            } label: {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 10))
            }
            .buttonStyle(.plain)
            .foregroundStyle(PulseTheme.accent)
            .accessibilityLabel(
                L10n.providers.editAccount(
                    accountDisplayLabel(config)
                )
            )

            Button {
                accountPendingRemoval = config
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 10))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.red)
            .accessibilityLabel(
                L10n.providers.removeNamedAccount(
                    accountDisplayLabel(config)
                )
            )
        }
        .padding(7)
        .background(Color.secondary.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private func accountIsConnected(
        _ config: ProviderConfig,
        usage: ProviderAccountUsage?
    ) -> Bool {
        if config.hasCredentials || usage != nil {
            return true
        }
        if config.kind == .gemini {
            return GeminiOAuthManager.shared.isConnected(
                accountID: config.accountID,
                allowLegacyFallback:
                    config.sharedCredentialFallbackDisabled != true
            )
        }
        return false
    }

    private func accountDisplayLabel(
        _ config: ProviderConfig
    ) -> String {
        if let label = config.accountLabel?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !label.isEmpty {
            return label
        }
        let configs = providerState.configs(for: config.kind)
        guard configs.count > 1,
              let index = configs.firstIndex(where: {
                  $0.accountID == config.accountID
              })
        else {
            return L10n.providers.defaultAccount
        }
        return L10n.providers.accountNumber(index + 1)
    }
}
