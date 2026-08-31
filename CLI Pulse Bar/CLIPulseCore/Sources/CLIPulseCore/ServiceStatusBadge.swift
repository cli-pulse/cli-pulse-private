// Provider service-status badge — the UI consumer for the ServiceStatus engine.
//
// A compact, self-contained badge that surfaces a provider's service-status
// incident (Atlassian Statuspage). It renders NOTHING when the provider has no
// known status page, when all systems are operational, or before the first
// fetch returns — so it adds zero clutter in the common case and only appears
// during an actual incident / maintenance window. Shared by the macOS
// `ProvidersTab` and iOS `iOSProvidersTab` provider cards.

#if canImport(SwiftUI)
import SwiftUI

public struct ServiceStatusBadge: View {
    private let provider: ProviderKind
    private let fetcher: ServiceStatusFetcher

    @State private var snapshot: ServiceStatusSnapshot?
    /// Read straight from the same defaults key the Settings toggle writes —
    /// the `machineControlsEnabled` precedent (AppState.swift:750), where the
    /// control and the affordance share one key so they cannot drift.
    @AppStorage("cli_pulse_check_provider_status") private var checkProviderStatus = true

    public init(provider: ProviderKind, fetcher: ServiceStatusFetcher = ServiceStatusFetcher()) {
        self.provider = provider
        self.fetcher = fetcher
    }

    public var body: some View {
        Group {
            if let snapshot, snapshot.indicator.shouldSurface {
                let tint = Self.tint(for: snapshot.indicator)
                HStack(spacing: 3) {
                    Circle()
                        .fill(tint)
                        .frame(width: 5, height: 5)
                    if !snapshot.description.isEmpty {
                        Text(snapshot.description)
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(tint)
                            .lineLimit(1)
                    }
                }
                .help(snapshot.description)
                .accessibilityElement()
                .accessibilityLabel(Text(verbatim: "\(provider.rawValue): \(snapshot.description)"))
            }
        }
        // Fetch this provider's status on appear (and if the provider identity
        // changes via view reuse). The fetcher returns nil immediately — no
        // network — for providers without a known status page, so unsupported
        // providers cost nothing.
        .task(id: provider) {
            // Honour the setting BEFORE any outbound request. It had no reader
            // until 2026-08-31, so switching it off still GET'd
            // status.claude.com, status.openai.com and friends — a network and
            // privacy promise the app was not keeping.
            guard checkProviderStatus else {
                snapshot = nil
                return
            }
            snapshot = await fetcher.fetch(provider)
        }
    }

    /// Severity → tint. `operational`/`unknown` never render (guarded by
    /// `shouldSurface`) but still need a concrete `Color` return.
    static func tint(for indicator: ServiceStatusIndicator) -> Color {
        switch indicator {
        case .minor: return .yellow
        case .major: return .orange
        case .critical: return .red
        case .maintenance: return .blue
        case .operational, .unknown: return .gray
        }
    }
}
#endif
