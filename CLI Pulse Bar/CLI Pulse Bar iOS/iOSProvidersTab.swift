import SwiftUI
import CLIPulseCore

struct iOSProvidersTab: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var providerState: ProviderState
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var showDisabled = false
    @State private var searchText = ""
    /// v1.10.7: kinds the user just toggled OFF in this view's lifetime.
    /// Without this, the filter below drops the card the moment the toggle
    /// flips, so the user can't tap it back on — they thought the control
    /// was broken. Sticky-visible until the user leaves the tab and returns.
    @State private var recentlyToggledOff: Set<ProviderKind> = []

    private var isIPad: Bool { horizontalSizeClass == .regular }

    private var accountGroups: [ProviderAccountGroup] {
        ProviderAccountPresentation.groups(
            providerState.providerAccounts
        )
    }

    private var accountOnlyGroups: [ProviderAccountGroup] {
        ProviderAccountPresentation.groups(
            providerState.providerAccounts,
            excluding: Set(
                visibleDetails.map(\.config.kind)
            )
        )
    }

    private func accounts(
        for provider: ProviderKind
    ) -> [ProviderAccountUsage] {
        accountGroups.first {
            $0.provider == provider
        }?.accounts ?? []
    }

    private var visibleDetails: [ProviderDetail] {
        providerState.providerDetails.filter {
            showDisabled
                || $0.config.isEnabled
                || recentlyToggledOff.contains($0.config.kind)
        }
    }

    /// `visibleDetails` narrowed by the search field (name match). Empty query =
    /// all, so search is additive over the show-disabled filter.
    private var filteredDetails: [ProviderDetail] {
        visibleDetails.filter {
            ProviderSearchFilter.matches(providerName: $0.provider.provider, query: searchText)
        }
    }

    private var filteredAccountOnlyGroups: [ProviderAccountGroup] {
        accountOnlyGroups.filter {
            ProviderSearchFilter.matches(
                providerName: $0.provider.rawValue,
                query: searchText
            )
        }
    }

    private func handleToggle(_ kind: ProviderKind, newValue: Bool) {
        if !newValue {
            recentlyToggledOff.insert(kind)
        } else {
            recentlyToggledOff.remove(kind)
        }
        state.setProviderEnabled(kind, isEnabled: newValue)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 12) {
                    // Cost bar
                    if state.showCost {
                        costBar
                            .padding(.horizontal)
                    }

                    if visibleDetails.isEmpty
                        && providerState.providers.isEmpty
                        && providerState.providerAccounts.isEmpty {
                        // Mobile never captures provider credentials. Whether
                        // or not the CLIPulse account is already paired, the
                        // actionable next step is to connect an agent on Mac.
                        iOSSyncOnboardingCard()
                            .environmentObject(state)
                            .padding(.horizontal)
                            .padding(.vertical, 20)
                    } else if visibleDetails.isEmpty
                        && accountOnlyGroups.isEmpty {
                        // v1.10.7: parity with macOS — when every provider is
                        // toggled off and the user hasn't hit "Show All", give
                        // them a clear path back instead of a blank screen.
                        ContentUnavailableView {
                            Label(L10n.providers.allHidden, systemImage: "eye.slash")
                        } description: {
                            Text(L10n.providers.showAllHint)
                        } actions: {
                            Button(L10n.providers.showAll) {
                                showDisabled = true
                            }
                            .buttonStyle(.borderedProminent)
                        }
                        .padding(.vertical, 40)
                    } else if filteredDetails.isEmpty
                        && filteredAccountOnlyGroups.isEmpty {
                        // No provider matches the active search query.
                        ContentUnavailableView {
                            Label(L10n.providers.noSearchMatch, systemImage: "magnifyingglass")
                        }
                        .padding(.vertical, 40)
                    } else if isIPad {
                        // iPad: two-column grid
                        LazyVGrid(columns: [
                            GridItem(.flexible(), spacing: 12),
                            GridItem(.flexible(), spacing: 12),
                        ], spacing: 12) {
                            ForEach(filteredDetails) { detail in
                                iOSEnhancedProviderCard(
                                    detail: detail,
                                    showCost: state.showCost,
                                    accountUsages: accounts(
                                        for: detail.config.kind
                                    ),
                                    dailyUsage: state.dailyUsage
                                ) { newValue in
                                    handleToggle(detail.config.kind, newValue: newValue)
                                }
                            }
                            ForEach(filteredAccountOnlyGroups) { group in
                                iOSAccountOnlyProviderCard(group: group)
                            }
                        }
                        .padding(.horizontal)
                    } else {
                        // iPhone: single column
                        ForEach(filteredDetails) { detail in
                            iOSEnhancedProviderCard(
                                detail: detail,
                                showCost: state.showCost,
                                accountUsages: accounts(
                                    for: detail.config.kind
                                ),
                                dailyUsage: state.dailyUsage
                            ) { newValue in
                                handleToggle(detail.config.kind, newValue: newValue)
                            }
                        }
                        ForEach(filteredAccountOnlyGroups) { group in
                            iOSAccountOnlyProviderCard(group: group)
                        }
                        .padding(.horizontal)
                    }
                }
                .padding(.vertical)
            }
            .navigationTitle(L10n.tab.providers)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button {
                            showDisabled.toggle()
                        } label: {
                            Label(showDisabled ? L10n.providers.hideDisabled : L10n.providers.showAll, systemImage: showDisabled ? "eye.slash" : "eye")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
                ToolbarItem(placement: .secondaryAction) {
                    Text(
                        "\(providerState.enabledProviderCount) "
                        + L10n.providers.tracked
                    )
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            .refreshable {
                await state.refreshAll()
            }
            .searchable(text: $searchText, prompt: L10n.providers.searchPlaceholder)
        }
    }

    private var costBar: some View {
        HStack(spacing: 20) {
            VStack(alignment: .leading, spacing: 2) {
                Text(L10n.dashboard.today)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Text(CostFormatter.format(providerState.costSummary.todayTotal))
                    .font(.headline.monospacedDigit())
                    .foregroundStyle(.green)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(L10n.dashboard.thirtyDayEst)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Text(CostFormatter.format(providerState.costSummary.thirtyDayTotal))
                    .font(.headline.monospacedDigit())
                    .foregroundStyle(.green)
            }
            Spacer()
        }
        .padding()
        .background(PulseTheme.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

/// Read-only fallback for a valid v2 account snapshot whose provider-level
/// aggregate row is temporarily unavailable. It intentionally has no local
/// provider toggle because cloud account identity is independent of the Mac's
/// `ProviderConfig` UUIDs.
struct iOSAccountOnlyProviderCard: View {
    let group: ProviderAccountGroup

    private var providerColor: Color {
        PulseTheme.providerColor(group.provider.rawValue)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: group.provider.iconName)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(providerColor)
                    .frame(width: 36, height: 36)
                    .background(providerColor.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 8))

                VStack(alignment: .leading, spacing: 2) {
                    Text(group.provider.rawValue)
                        .font(.headline)
                    Text(
                        L10n.providers.accountsCount(
                            group.accounts.count
                        )
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                Spacer()
            }

            iOSProviderAccountSection(
                provider: group.provider,
                accounts: group.accounts,
                showsProviderCostNote: false
            )
        }
        .padding()
        .background(PulseTheme.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(providerColor.opacity(0.2), lineWidth: 1)
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel(
            "\(group.provider.rawValue), "
            + L10n.providers.accountsCount(
                group.accounts.count
            )
        )
    }
}

// MARK: - Enhanced Provider Card for iOS

struct iOSEnhancedProviderCard: View {
    let detail: ProviderDetail
    let showCost: Bool
    /// Credential-free, normalized account snapshots synced from the Mac.
    /// Cost remains on `detail.provider` and is deliberately not copied here.
    let accountUsages: [ProviderAccountUsage]
    /// v1.30 F3 — cached daily usage (from AppState) for the history chart.
    /// Passed in (this card has no AppState environment object).
    var dailyUsage: [DailyUsage] = []
    /// v1.10.7: receives the exact new toggle value instead of an implicit flip.
    /// Mirrors the macOS card contract and removes the last-write-wins race
    /// that made rapid double-taps appear to not re-enable a provider.
    let onToggle: (Bool) -> Void

    private var provider: ProviderUsage { detail.provider }
    private var config: ProviderConfig { detail.config }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header
            HStack(spacing: 10) {
                Image(systemName: config.kind.iconName)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(providerColor)
                    .frame(width: 36, height: 36)
                    .background(providerColor.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 8))

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        Text(provider.provider)
                            .font(.headline)
                        Circle()
                            .fill(statusColor)
                            .frame(width: 6, height: 6)
                        if let plan = provider.plan_type, plan != "Unknown", plan != "Free" {
                            Text(plan)
                                .font(.system(size: 9, weight: .medium))
                                .foregroundStyle(.orange)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background(Color.orange.opacity(0.12))
                                .clipShape(Capsule())
                        }
                        if let meta = provider.metadata {
                            CategoryBadge(category: meta.category)
                        }
                    }
                    HStack(spacing: 4) {
                        Text(provider.status_text)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if showCost {
                            CostStatusBadge(status: provider.cost_status_today)
                        }
                        // Provider service-status (incident/maintenance) — renders
                        // nothing unless this provider's status page reports an issue.
                        if let kind = ProviderKind(rawValue: provider.provider) {
                            ServiceStatusBadge(provider: kind)
                        }
                    }
                }
                Spacer()

                Toggle("", isOn: Binding(
                    get: { config.isEnabled },
                    set: { newValue in onToggle(newValue) }
                ))
                .labelsHidden()
                .accessibilityLabel(
                    L10n.providers.monitorAccount(
                        provider.provider
                    )
                )
            }

            // Provider status page — expandable "Service Status" component list
            // + "Open Status Page" link (nothing for providers without a page).
            if let kind = ProviderKind(rawValue: provider.provider) {
                ProviderStatusComponentsView(provider: kind)
            }

            if !accountUsages.isEmpty {
                iOSProviderAccountSection(
                    provider: config.kind,
                    accounts: accountUsages,
                    showsProviderCostNote: true
                )
            }

            if config.isEnabled {
                // Usage stats
                HStack(spacing: 20) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L10n.dashboard.today)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                        Text(CostFormatter.formatUsage(provider.today_usage))
                            .font(.title3.weight(.bold).monospacedDigit())
                        if showCost {
                            Text(CostFormatter.format(provider.estimated_cost_today))
                                .font(.caption.weight(.medium))
                                .foregroundStyle(.green)
                        }
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L10n.providers.thisWeek)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                        Text(CostFormatter.formatUsage(provider.week_usage))
                            .font(.title3.weight(.bold).monospacedDigit())
                        if showCost {
                            Text(CostFormatter.format(provider.estimated_cost_week))
                                .font(.caption.weight(.medium))
                                .foregroundStyle(.green)
                        }
                    }
                    Spacer()
                    if accountUsages.isEmpty {
                        // Legacy provider-only snapshots still need their
                        // aggregate quota badge. V2 quota is rendered inside
                        // each account row to avoid attributing one account's
                        // pressure to every account in the provider.
                        quotaBadge
                    }
                }

                // Legacy provider-only fallback. V2 account snapshots render
                // their quota windows in `iOSProviderAccountSection`.
                if accountUsages.isEmpty && !detail.tiers.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(detail.tiers) { tier in
                            UsageBar(
                                label: tier.name,
                                value: 1.0 - tier.usagePercent,
                                color: tierColor(tier),
                                detail: tierDetail(tier),
                                markers: paceMarkers(for: tier)
                            )
                        }
                    }
                } else if accountUsages.isEmpty,
                          let quota = provider.quota,
                          quota > 0 {
                    UsageBar(
                        label: L10n.providers.quota,
                        value: provider.usagePercent,
                        color: usageColor,
                        detail: remainingText
                    )
                }

                // v1.23 G4: CodexBar-parity usage-pace forecast,
                // mirroring the macOS providers card. Engine-gated to
                // Codex/Claude with a valid future reset anchor; nil ⇒
                // the row is absent (intentional ragged-row design
                // since v1.18.2 — Gemini R1 CRITICAL verified: no new
                // misalignment class introduced).
                if accountUsages.isEmpty,
                   let paceSummary = provider.paceSummary() {
                    HStack(spacing: 4) {
                        Image(systemName: "gauge.with.needle")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                        Text(paceSummary)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }

                // v1.30 F3 — per-provider daily usage history (last 30 days),
                // shown only when there's history. `dailyUsage` is passed in
                // from AppState (this card has no environment object).
                let usageHistory = ProviderUsageHistory.series(from: dailyUsage, provider: provider.provider)
                if usageHistory.contains(where: { $0.ioTokens > 0 }) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(L10n.widget.usageTitle)
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(.secondary)
                        ProviderUsageHistoryChart(points: usageHistory, accent: providerColor)
                    }
                    .padding(.top, 2)
                }
            }
        }
        .padding()
        .background(PulseTheme.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(providerColor.opacity(config.isEnabled ? 0.2 : 0.05), lineWidth: 1)
        )
        .opacity(config.isEnabled ? 1.0 : 0.6)
        // v1.10 P3-3: card header summary for VoiceOver. Tiers/bars inside
        // keep their own accessibility so the user can drill in; this label
        // is a quick summary when the card is focused.
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilitySummary)
    }

    private var accessibilitySummary: String {
        var parts: [String] = [provider.provider]
        parts.append(config.isEnabled ? "enabled" : "disabled")
        parts.append(provider.status_text)
        if !accountUsages.isEmpty {
            parts.append(
                L10n.providers.accountsCount(
                    accountUsages.count
                )
            )
        }
        if let quota = provider.quota, quota > 0 {
            let pct = Int(round(provider.usagePercent * 100))
            parts.append("\(pct)% used")
        }
        return parts.joined(separator: ", ")
    }

    private var providerColor: Color { PulseTheme.providerColor(provider.provider) }

    private var statusColor: Color {
        switch detail.operationalStatus {
        case .operational: return .green
        case .degraded: return .orange
        case .down: return .red
        }
    }

    private var usageColor: Color {
        if provider.usagePercent > 0.9 { return .red }
        if provider.usagePercent > 0.7 { return .orange }
        return providerColor
    }

    private var remainingText: String? {
        guard let remaining = provider.remaining else { return nil }
        return L10n.detail.remainingValue(CostFormatter.formatUsage(remaining))
    }

    /// v1.30 F2 — expected-pace marker + configured warning-threshold ticks for
    /// an iOS tier bar (remaining-oriented, `value: 1 - usagePercent`),
    /// mirroring the macOS wiring.
    private func paceMarkers(for tier: UsageTier) -> [BarMarker] {
        var markers: [BarMarker] = []
        if let used = QuotaBarMarkers.expectedPaceFraction(tier: tier) {
            markers.append(BarMarker(position: QuotaBarMarkers.place(used, onRemainingBar: true), kind: .pace))
        }
        let thresholds = QuotaBarMarkers.warningFractions(
            thresholdsPercent: AlertThresholdsStore.load().asArray)
        markers += thresholds.map {
            BarMarker(position: QuotaBarMarkers.place($0, onRemainingBar: true), kind: .threshold)
        }
        return markers
    }

    private func tierColor(_ tier: UsageTier) -> Color {
        if tier.usagePercent > 0.9 { return .red }
        if tier.usagePercent > 0.7 { return .orange }
        return providerColor
    }

    private func tierDetail(_ tier: UsageTier) -> String? {
        guard let remaining = tier.remaining, let quota = tier.quota, quota > 0 else { return nil }
        let pctLeft = Int(100.0 * Double(remaining) / Double(quota))
        var result = "\(pctLeft)% left"
        if let reset = tier.resetTime,
           let resetText = RelativeTime.formatReset(reset) {
            result += " · Resets \(resetText)"
        }
        return result
    }

    private var quotaBadge: some View {
        Group {
            if provider.usagePercent > 0.9 {
                StatusBadge(text: L10n.quota.low, color: .red)
            } else if provider.usagePercent > 0.7 {
                StatusBadge(text: L10n.quota.moderate, color: .orange)
            } else {
                StatusBadge(text: L10n.quota.ok, color: .green)
            }
        }
    }
}

// MARK: - Provider → Account hierarchy

struct iOSProviderAccountSection: View {
    let provider: ProviderKind
    let accounts: [ProviderAccountUsage]
    let showsProviderCostNote: Bool

    private var sortedAccounts: [ProviderAccountUsage] {
        ProviderAccountPresentation.groups(accounts)
            .first { $0.provider == provider }?
            .accounts ?? []
    }

    private var latestFreshness: String? {
        ProviderAccountPresentation.latestFreshnessTimestamp(
            in: sortedAccounts
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Label(
                    L10n.providers.accountsCount(
                        sortedAccounts.count
                    ),
                    systemImage: "person.2"
                )
                .font(.caption.weight(.semibold))

                Spacer()

                if let latestFreshness {
                    Text(
                        L10n.dashboard.updated(
                            RelativeTime.format(latestFreshness)
                        )
                    )
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                }
            }

            ForEach(
                Array(sortedAccounts.enumerated()),
                id: \.element.id
            ) { index, account in
                iOSProviderAccountRow(
                    account: account,
                    fallbackLabel:
                        sortedAccounts.count == 1
                            ? L10n.providers.defaultAccount
                            : L10n.providers.accountNumber(
                                index + 1
                            )
                )
            }

            if showsProviderCostNote {
                Label(
                    L10n.providers.providerLevelCost,
                    systemImage: "info.circle"
                )
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(10)
        .background(Color.secondary.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}

struct iOSProviderAccountRow: View {
    let account: ProviderAccountUsage
    let fallbackLabel: String

    private var accountLabel: String {
        let trimmed = account.accountLabel?
            .trimmingCharacters(
                in: .whitespacesAndNewlines
            )
        if let trimmed, !trimmed.isEmpty {
            return trimmed
        }
        return fallbackLabel
    }

    private var planLabel: String {
        account.planEvidence.displayValue
            ?? account.planEvidence.rawValue
            ?? L10n.providers.planUnconfirmed
    }

    private var freshness: String? {
        ProviderAccountPresentation.freshnessTimestamp(
            for: account
        )
    }

    private var validTiers: [TierDTO] {
        account.tiers.filter { $0.quota > 0 }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(accountLabel)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)

                Text(planLabel)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(Color.orange.opacity(0.1))
                    .clipShape(Capsule())

                Spacer()
            }

            HStack(spacing: 8) {
                Text(
                    L10n.providers.sourceLabel(
                        L10n.providers.planSource(
                            account.planEvidence.source
                        )
                    )
                )
                .lineLimit(1)

                if let freshness {
                    Text(
                        L10n.dashboard.updated(
                            RelativeTime.format(freshness)
                        )
                    )
                    .lineLimit(1)
                }
            }
            .font(.caption2)
            .foregroundStyle(.tertiary)

            if !validTiers.isEmpty {
                ForEach(
                    Array(validTiers.enumerated()),
                    id: \.offset
                ) { _, tier in
                    let fraction = remainingFraction(
                        remaining: tier.remaining,
                        quota: tier.quota
                    )
                    UsageBar(
                        label: tier.name,
                        value: fraction,
                        color: quotaColor(fraction),
                        detail: quotaDetail(
                            remaining: tier.remaining,
                            quota: tier.quota,
                            resetTime: tier.reset_time
                        )
                    )
                }
            } else if let quota = account.quota,
                      quota > 0,
                      let remaining = account.remaining {
                let fraction = remainingFraction(
                    remaining: remaining,
                    quota: quota
                )
                UsageBar(
                    label: L10n.providers.quota,
                    value: fraction,
                    color: quotaColor(fraction),
                    detail: quotaDetail(
                        remaining: remaining,
                        quota: quota,
                        resetTime: account.resetTime
                    )
                )
            } else {
                Text(account.statusText)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(9)
        .background(PulseTheme.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(
            "\(accountLabel), \(planLabel), "
            + account.statusText
        )
    }

    private func remainingFraction(
        remaining: Int,
        quota: Int
    ) -> Double {
        min(max(Double(remaining) / Double(quota), 0), 1)
    }

    private func quotaColor(
        _ remainingFraction: Double
    ) -> Color {
        if remainingFraction <= 0.1 { return .red }
        if remainingFraction <= 0.25 { return .orange }
        return PulseTheme.providerColor(
            account.provider.rawValue
        )
    }

    private func quotaDetail(
        remaining: Int,
        quota: Int,
        resetTime: String?
    ) -> String {
        var detail = "\(remaining) / \(quota)"
        if let resetTime,
           let reset = RelativeTime.formatReset(resetTime) {
            detail += " · \(reset)"
        }
        return detail
    }
}
