import SwiftUI
import CLIPulseCore

/// Presentation-only account option assembled from passive discovery metadata,
/// existing non-secret ProviderConfig fields, and any already-normalized usage.
/// It deliberately carries no credential value or connection side effect.
struct AgentSetupAccountOption: Identifiable, Equatable {
    let id: UUID
    let provider: ProviderKind
    let accountLabel: String
    let planLabel: String?
    let status: ProviderDiscoveryStatus
    let signals: Set<ProviderDiscoverySignal>
}

struct ProviderAccountSetupCard: View {
    let option: AgentSetupAccountOption
    let isSelected: Bool
    var isReadOnly = false
    var onToggle: (() -> Void)?
    var onConnect: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: option.provider.iconName)
                    .font(.title3)
                    .foregroundStyle(PulseTheme.accent)
                    .frame(width: 28, height: 28)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 3) {
                    Text(option.provider.rawValue)
                        .font(.headline)
                    Text(option.accountLabel)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 8)

                statusBadge
            }

            HStack(spacing: 6) {
                Image(systemName: "sparkles")
                    .accessibilityHidden(true)
                Text(
                    option.planLabel
                        ?? L10n.onboardingWizard.planUnconfirmed
                )
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            if !option.signals.isEmpty {
                Text(signalSummary)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !isReadOnly {
                HStack(spacing: 10) {
                    Toggle(
                        L10n.onboardingWizard.enableMonitoring,
                        isOn: Binding(
                            get: { isSelected },
                            set: { _ in onToggle?() }
                        )
                    )
                    .toggleStyle(.switch)
                    .controlSize(.small)

                    Spacer()

                    if let onConnect,
                       option.status != .connected {
                        Button(
                            L10n.onboardingWizard.connect,
                            action: onConnect
                        )
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
            } else if isSelected {
                Label(
                    L10n.onboardingWizard.monitoringEnabled,
                    systemImage: "checkmark.circle.fill"
                )
                .font(.caption)
                .foregroundStyle(.green)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(
                    isSelected
                        ? PulseTheme.accent.opacity(0.55)
                        : Color.secondary.opacity(0.16),
                    lineWidth: isSelected ? 1.5 : 1
                )
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel(
            "\(option.provider.rawValue), \(option.accountLabel)"
        )
        .accessibilityValue(
            isSelected
                ? L10n.onboardingWizard.monitoringEnabled
                : L10n.onboardingWizard.monitoringDisabled
        )
    }

    private var statusBadge: some View {
        Label(statusLabel, systemImage: statusIcon)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(statusColor)
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(
                Capsule()
                    .fill(statusColor.opacity(0.12))
            )
    }

    private var statusLabel: String {
        switch option.status {
        case .detected:
            return L10n.onboardingWizard.statusDetected
        case .connected:
            return L10n.onboardingWizard.statusConnected
        case .actionRequired:
            return L10n.onboardingWizard.statusActionRequired
        case .notFound:
            return L10n.onboardingWizard.statusNotFound
        }
    }

    private var statusIcon: String {
        switch option.status {
        case .detected:
            return "magnifyingglass.circle.fill"
        case .connected:
            return "checkmark.circle.fill"
        case .actionRequired:
            return "exclamationmark.circle.fill"
        case .notFound:
            return "minus.circle"
        }
    }

    private var statusColor: Color {
        switch option.status {
        case .detected:
            return .blue
        case .connected:
            return .green
        case .actionRequired:
            return .orange
        case .notFound:
            return .secondary
        }
    }

    private var signalSummary: String {
        option.signals
            .sorted { $0.rawValue < $1.rawValue }
            .map { signal in
                switch signal {
                case .installedCLI:
                    return L10n.onboardingWizard.signalCLI
                case .configurationFile:
                    return L10n.onboardingWizard.signalConfig
                case .authorizedBookmark:
                    return L10n.onboardingWizard.signalBookmark
                case .existingConfiguration:
                    return L10n.onboardingWizard.signalExisting
                case .knownConnection:
                    return L10n.onboardingWizard.signalConnected
                }
            }
            .joined(separator: " · ")
    }
}
