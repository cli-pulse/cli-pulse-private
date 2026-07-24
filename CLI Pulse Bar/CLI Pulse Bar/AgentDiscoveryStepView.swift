import SwiftUI
import CLIPulseCore

struct AgentDiscoveryStepView: View {
    let options: [AgentSetupAccountOption]
    let selectedAccountIDs: Set<UUID>
    let undetectedProviderCount: Int
    let isScanning: Bool
    let onToggle: (UUID) -> Void
    let onConnect: (UUID) -> Void
    let onRescan: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            VStack(spacing: 5) {
                Text(L10n.onboardingWizard.discoveryTitle)
                    .font(.title3.weight(.semibold))
                Text(L10n.onboardingWizard.discoverySubtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if isScanning {
                ProgressView(L10n.onboardingWizard.scanning)
                    .controlSize(.small)
                    .frame(maxHeight: .infinity)
            } else if options.isEmpty {
                ContentUnavailableView {
                    Label(
                        L10n.onboardingWizard.noAgentsTitle,
                        systemImage: "terminal"
                    )
                } description: {
                    Text(L10n.onboardingWizard.noAgentsBody)
                } actions: {
                    Button(
                        L10n.onboardingWizard.scanAgain,
                        action: onRescan
                    )
                    .buttonStyle(.bordered)
                }
                .frame(maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(options) { option in
                            ProviderAccountSetupCard(
                                option: option,
                                isSelected:
                                    selectedAccountIDs.contains(option.id),
                                onToggle: {
                                    onToggle(option.id)
                                },
                                onConnect: option.status == .connected
                                    ? nil
                                    : {
                                        onConnect(option.id)
                                    }
                            )
                        }
                    }
                    .padding(.horizontal, 2)
                }

                HStack {
                    if undetectedProviderCount > 0 {
                        Text(
                            L10n.onboardingWizard
                                .undetectedProviders(
                                    undetectedProviderCount
                                )
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Button(
                        L10n.onboardingWizard.scanAgain,
                        action: onRescan
                    )
                    .buttonStyle(.plain)
                    .font(.caption)
                    .disabled(isScanning)
                }
            }
        }
        .accessibilityElement(children: .contain)
    }
}
