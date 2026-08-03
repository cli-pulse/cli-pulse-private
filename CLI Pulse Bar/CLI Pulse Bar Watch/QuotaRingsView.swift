import SwiftUI
import CLIPulseCore

/// Quota page. Concentric rings show **remaining** headroom (countdown,
/// matching macOS/iOS and the watch-face complication) for the top-3
/// most-constrained providers; below, each provider gets per-window
/// quota bars (5h / Weekly / …) that also count down, reusing the shared
/// `UsageBar` so the watch reads identically to the phone & Mac.
///
/// Presentation-only — reads `state.*` (incl. the already-synced
/// `ProviderUsage.tiers`), never mutates the data layer. One `ScrollView`
/// (review R1).
struct QuotaRingsView: View {
    @EnvironmentObject var state: WatchAppState

    private var visibleProviders: [ProviderUsage] {
        state.providers.filter { state.enabledProviderNames.contains($0.provider) }
    }

    /// Per-provider cards, least Weekly headroom first — matching the
    /// Weekly-window numbers the rings + card headers display, so the order
    /// reflects the risk the user actually sees.
    private var sortedProviders: [ProviderUsage] {
        let ranks = Dictionary(
            uniqueKeysWithValues:
                WatchRingMath.orderedQuotaSnapshots(
                    visibleProviders,
                    accounts: state.enabledProviderAccounts
                )
                .enumerated()
                .map { ($0.element.id, $0.offset) }
        )
        return visibleProviders.sorted { a, b in
            switch (ranks[a.id], ranks[b.id]) {
            case let (lhs?, rhs?):
                return lhs < rhs
            case (_?, nil):
                return true
            case (nil, _?):
                return false
            case (nil, nil):
                return a.provider < b.provider
            }
        }
    }

    /// Concentric rings: metered providers, most-constrained first, capped
    /// at 3 for legibility. Shared math so rings can't diverge from the
    /// bars / complication.
    private var ringSnapshots: [WatchProviderQuotaSnapshot] {
        WatchRingMath.liveRingSnapshots(
            visibleProviders,
            accounts: state.enabledProviderAccounts,
            limit: 3
        )
    }

    private var meteredCount: Int {
        visibleProviders.compactMap { provider in
            WatchRingMath.quotaSnapshot(
                for: provider,
                accounts: state.enabledProviderAccounts
            )
        }
        .count
    }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 10) {
                header

                if visibleProviders.isEmpty {
                    if state.isLoading && state.lastRefresh == nil {
                        WatchLoadingState()
                    } else if let err = state.lastError {
                        WatchErrorState(title: L10n.watch.couldntLoadProviders, message: err) {
                            Task { await state.refreshAll() }
                        }
                    } else {
                        emptyState
                    }
                } else {
                    if !ringSnapshots.isEmpty {
                        ProviderRingCluster(
                            snapshots: ringSnapshots
                        )
                            .frame(height: 142)
                            .padding(.vertical, 2)
                        // Legend mapping each ring's colour → its provider
                        // (outer ring first), so the concentric rings are
                        // readable at a glance.
                        RingLegend(snapshots: ringSnapshots)
                    }
                    ForEach(sortedProviders) { provider in
                        let accounts = state.accounts(
                            for: provider.provider
                        )
                        NavigationLink {
                            if accounts.count > 1 {
                                WatchProviderAccountsDetailView(
                                    provider: provider,
                                    accounts: accounts,
                                    showCost: state.showCost
                                )
                            } else {
                                WatchProviderDetailView(
                                    provider: provider,
                                    account: accounts.first,
                                    showCost: state.showCost
                                )
                            }
                        } label: {
                            ProviderTierCard(
                                provider: provider,
                                accounts: accounts,
                                showCost: state.showCost
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(.horizontal, 2)
        }
        .refreshable { await state.refreshAll() }
    }

    private var header: some View {
        HStack {
            Text(L10n.providers.quota)
                .font(.system(size: 13, weight: .semibold))
            Spacer()
            if meteredCount > 0 {
                Text(L10n.watch.activeCount(meteredCount))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "cpu")
                .font(.title3)
                .foregroundStyle(.tertiary)
            Text(L10n.providers.noData)
                .font(.caption)
                .foregroundStyle(.secondary)
            if state.providerDataLoaded {
                Text(L10n.watch.connectAgentsOnMac)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
    }
}

// MARK: - Quota math/colour helpers (shared by the cards + detail)

enum QuotaTierStyle {
    /// Colour for a tier, red/amber when nearly exhausted (keyed on
    /// consumption like macOS `tierColor`, > 0.9 / > 0.7).
    static func color(quota: Int, remaining: Int, base: Color) -> Color {
        WatchTheme.tierColor(WatchRingMath.tier(usagePercent: WatchRingMath.usagePercent(quota: quota, remaining: remaining)), base: base)
    }
    /// "38% left" detail string for a tier.
    static func detail(quota: Int, remaining: Int) -> String {
        L10n.watch.percentLeft(WatchRingMath.remainingPercentInt(quota: quota, remaining: remaining))
    }
}

// MARK: - Concentric ring cluster (remaining / countdown)

/// Activity-ring-style concentric rings. `snapshots` is already filtered to
/// fresh account-aware quota values and ordered by tightest headroom.
struct ProviderRingCluster: View {
    let snapshots: [WatchProviderQuotaSnapshot]

    var body: some View {
        ZStack {
            ForEach(
                Array(snapshots.enumerated()),
                id: \.element.id
            ) { idx, snapshot in
                ring(for: snapshot, index: idx)
            }
            centerLabel
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilitySummary)
    }

    private func ring(
        for snapshot: WatchProviderQuotaSnapshot,
        index: Int
    ) -> some View {
        let provider = snapshot.provider
        // Each ring is drawn in the provider's OWN brand colour (stable, never
        // recoloured by usage) so a provider is identifiable by its ring colour
        // and the legend below can map colour → provider. Urgency is conveyed by
        // the arc length (how empty the ring is) and by the per-provider cards,
        // which keep the red/amber tier tinting.
        let base = PulseTheme.providerColor(provider.provider)
        // Inset each successive ring so it nests inside the previous one;
        // the +ringWidth/2 keeps the outermost stroke from clipping the edge.
        let inset = WatchTheme.ringWidth / 2
            + CGFloat(index) * (WatchTheme.ringWidth + WatchTheme.ringGap)
        return ZStack {
            Circle()
                .stroke(base.opacity(WatchTheme.ringTrackOpacity), lineWidth: WatchTheme.ringWidth)
            Circle()
                .trim(
                    from: 0,
                    to: snapshot.remainingFraction
                )
                .stroke(base, style: StrokeStyle(lineWidth: WatchTheme.ringWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .padding(inset)
    }

    @ViewBuilder
    private var centerLabel: some View {
        if let top = snapshots.first {
            // Constrained to the innermost ring's ~72pt opening so a long or
            // localized provider name shrinks/truncates instead of spilling
            // over the rings.
            VStack(spacing: 0) {
                Text("\(top.remainingPercent)%")
                    .font(WatchTheme.monoNumber(size: 22))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Text(
                    L10n.watch.providerLeft(
                        top.provider.provider
                    )
                )
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .frame(maxWidth: 76)
            .padding(.horizontal, 2)
        }
    }

    private var accessibilitySummary: String {
        snapshots
            .map {
                L10n.widget.percentLeft(
                    $0.provider.provider,
                    $0.remainingPercent
                )
            }
            .joined(separator: ", ")
    }
}

// MARK: - Ring legend (colour → provider)

/// Maps each concentric ring's colour to its account-aware provider snapshot.
struct RingLegend: View {
    let snapshots: [WatchProviderQuotaSnapshot]

    var body: some View {
        VStack(spacing: 4) {
            ForEach(
                Array(snapshots.enumerated()),
                id: \.element.id
            ) { _, snapshot in
                HStack(spacing: 6) {
                    Circle()
                        .fill(
                            PulseTheme.providerColor(
                                snapshot.provider.provider
                            )
                        )
                        .frame(width: 8, height: 8)
                    Text(snapshot.provider.provider)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    Spacer(minLength: 4)
                    Text(
                        L10n.watch.percentLeft(
                            snapshot.remainingPercent
                        )
                    )
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity)
        .background(WatchTheme.cardFill, in: RoundedRectangle(cornerRadius: WatchTheme.cardRadius))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(legendAccessibility)
    }

    private var legendAccessibility: String {
        snapshots
            .map {
                L10n.widget.percentLeft(
                    $0.provider.provider,
                    $0.remainingPercent
                )
            }
            .joined(separator: ", ")
    }
}

// MARK: - Per-provider tier card (5h / Weekly countdown bars)

/// One card per provider: name + its per-window quota bars (5h, Weekly, …)
/// shown as **remaining** (counting down). Caps at the first 2 windows for
/// the glance (collectors order the primary 5h + Weekly first); the full
/// set is on the detail view. Falls back to a single overall bar when the
/// provider reports no tiers, and to a plain "—" when it has no quota
/// window at all (matching macOS/iOS).
/// v1.30 F2 — expected-pace marker for a watch tier bar (remaining-oriented).
/// Watch shows the pace marker only; warning thresholds aren't synced here.
private func watchPaceMarkers(_ tier: TierDTO) -> [BarMarker] {
    guard let used = QuotaBarMarkers.expectedPaceFraction(tier: tier) else { return [] }
    return [BarMarker(position: QuotaBarMarkers.place(used, onRemainingBar: true), kind: .pace)]
}

func watchAccountLabel(
    _ account: ProviderAccountUsage,
    in accounts: [ProviderAccountUsage]
) -> String {
    let trimmed = account.accountLabel?
        .trimmingCharacters(in: .whitespacesAndNewlines)
    if let trimmed, !trimmed.isEmpty {
        return trimmed
    }
    guard accounts.count > 1 else {
        return L10n.providers.defaultAccount
    }
    let index = accounts.firstIndex {
        $0.id == account.id
    } ?? 0
    return L10n.providers.accountNumber(index + 1)
}

struct ProviderTierCard: View {
    let provider: ProviderUsage
    let accounts: [ProviderAccountUsage]
    let showCost: Bool

    private var providerColor: Color { PulseTheme.providerColor(provider.provider) }

    private var constrainedAccount: ProviderAccountUsage? {
        ProviderAccountPresentation
            .mostConstrainedEnabledAccount(in: accounts)
    }

    private var isMultiAccount: Bool {
        accounts.count > 1
    }

    private var displayedAccount: ProviderAccountUsage? {
        constrainedAccount ?? accounts.first
    }

    private var quotaSnapshot: WatchProviderQuotaSnapshot? {
        WatchRingMath.quotaSnapshot(
            for: provider,
            accounts: accounts
        )
    }

    private var isStale: Bool {
        quotaSnapshot?.isStale == true
    }

    private var displayedTiers: [TierDTO] {
        displayedAccount?.tiers ?? provider.tiers
    }

    private var overallRemainingFraction: Double? {
        quotaSnapshot?.remainingFraction
    }

    private var overallColor: Color {
        guard !isStale else { return .gray }
        return WatchTheme.tierColor(
            WatchRingMath.tier(
                usagePercent:
                    1 - (overallRemainingFraction ?? 1)
            ),
            base: providerColor
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Circle()
                    .fill(providerColor)
                    .frame(width: 8, height: 8)
                Text(
                    isMultiAccount
                        ? "\(provider.provider) · "
                            + L10n.providers.accountsCount(
                                accounts.count
                            )
                        : provider.provider
                )
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                Spacer(minLength: 4)
                if let overallRemainingFraction {
                    Text(
                        L10n.watch.percentLeft(
                            Int(overallRemainingFraction * 100)
                        )
                    )
                        .font(WatchTheme.monoNumber(size: 12))
                        .foregroundStyle(overallColor)
                }
            }

            if isMultiAccount, let constrainedAccount {
                Text(
                    L10n.watch.tightestAccount(
                        watchAccountLabel(
                            constrainedAccount,
                            in: accounts
                        )
                    )
                )
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }

            if !displayedTiers.isEmpty {
                ForEach(
                    Array(displayedTiers.prefix(2).enumerated()),
                    id: \.offset
                ) { _, tier in
                    UsageBar(
                        label: tier.name,
                        value: WatchRingMath.remainingFraction(quota: tier.quota, remaining: tier.remaining),
                        color:
                            isStale
                                ? .gray
                                : QuotaTierStyle.color(
                                    quota: tier.quota,
                                    remaining: tier.remaining,
                                    base: providerColor
                                ),
                        detail: QuotaTierStyle.detail(quota: tier.quota, remaining: tier.remaining),
                        markers:
                            isStale
                                ? []
                                : watchPaceMarkers(tier)
                    )
                }
            } else if let quota = displayedAccount?.quota,
                      quota > 0,
                      let remaining = displayedAccount?.remaining {
                let fraction = WatchRingMath.remainingFraction(
                    quota: quota,
                    remaining: remaining
                )
                UsageBar(
                    label: L10n.providers.quota,
                    value: fraction,
                    color: overallColor,
                    detail: L10n.watch.percentLeft(
                        Int(fraction * 100)
                    )
                )
            } else if provider.quota != nil {
                UsageBar(
                    label: L10n.providers.quota,
                    value: WatchRingMath.remainingFraction(usagePercent: provider.usagePercent),
                    color: overallColor,
                    detail: L10n.watch.percentLeft(WatchRingMath.remainingPercentInt(usagePercent: provider.usagePercent))
                )
            }

            if accounts.isEmpty,
               !isStale,
               let pace = provider.paceSummary() {
                Text(pace)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }

            if let freshnessAccount = displayedAccount {
                WatchAccountFreshnessLabel(
                    account: freshnessAccount
                )
            }

            // Provider-level cost is deliberately rendered once here, never
            // inside an account row.
            HStack(spacing: 4) {
                if showCost && provider.estimated_cost_today > 0 {
                    Text(L10n.dashboard.today)
                        .foregroundStyle(.secondary)
                    Text(CostFormatter.format(provider.estimated_cost_today))
                        .foregroundStyle(.green)
                    Text("·")
                        .foregroundStyle(.tertiary)
                }
                // v1.30 F4 — "—" when there's no token figure today (matches
                // macOS; "0 tokens" wrongly implied zero usage, not no data).
                if provider.today_usage > 0 {
                    Text(L10n.watch.tokensUsed(CostFormatter.formatUsage(provider.today_usage)))
                        .foregroundStyle(.secondary)
                } else {
                    Text("—").foregroundStyle(.tertiary)
                }
                Spacer(minLength: 0)
            }
            .font(.caption2.monospacedDigit())
        }
        .padding(8)
        .background(WatchTheme.cardFill, in: RoundedRectangle(cornerRadius: WatchTheme.cardRadius))
        .accessibilityElement(children: .combine)
    }
}

struct WatchAccountFreshnessLabel: View {
    let account: ProviderAccountUsage

    private var timestamp: String? {
        ProviderAccountPresentation.freshnessTimestamp(
            for: account
        )
    }

    private var isStale: Bool {
        ProviderAccountPresentation.isStale(account)
    }

    private var text: String {
        guard let timestamp else {
            return L10n.watch.staleUpdated("—")
        }
        let relative = RelativeTime.format(timestamp)
        return isStale
            ? L10n.watch.staleUpdated(relative)
            : L10n.dashboard.updated(relative)
    }

    var body: some View {
        Label(
            text,
            systemImage:
                isStale
                    ? "clock.badge.exclamationmark"
                    : "clock"
        )
        .font(.caption2)
        .foregroundStyle(
            isStale
                ? Color.orange
                : Color.secondary.opacity(0.7)
        )
        .lineLimit(1)
        .minimumScaleFactor(0.75)
        .accessibilityLabel(text)
    }
}

struct WatchProviderAccountsDetailView: View {
    let provider: ProviderUsage
    let accounts: [ProviderAccountUsage]
    let showCost: Bool

    private var providerColor: Color {
        PulseTheme.providerColor(provider.provider)
    }

    private var sortedAccounts: [ProviderAccountUsage] {
        ProviderAccountPresentation.enabledGroups(accounts)
            .first?
            .accounts ?? []
    }

    private var constrainedAccount: ProviderAccountUsage? {
        ProviderAccountPresentation
            .mostConstrainedEnabledAccount(
                in: sortedAccounts
            )
    }

    var body: some View {
        List {
            Section {
                HStack(spacing: 8) {
                    Image(
                        systemName:
                            provider.providerKind?.iconName
                                ?? "cpu"
                    )
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(providerColor)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(provider.provider)
                            .font(.headline)
                            .lineLimit(1)
                        Text(
                            L10n.providers.accountsCount(
                                sortedAccounts.count
                            )
                        )
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    }
                }

                if let constrainedAccount {
                    Text(
                        L10n.watch.tightestAccount(
                            watchAccountLabel(
                                constrainedAccount,
                                in: sortedAccounts
                            )
                        )
                    )
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                }
            }

            Section(L10n.dashboard.today) {
                WatchMetricRow(
                    label: L10n.widget.usageTitle,
                    value:
                        provider.today_usage > 0
                            ? CostFormatter.formatUsage(
                                provider.today_usage
                            )
                            : "—",
                    icon: "chart.bar.fill"
                )
                if showCost {
                    WatchMetricRow(
                        label: L10n.dashboard.costToday,
                        value: CostFormatter.format(
                            provider.estimated_cost_today
                        ),
                        icon: "dollarsign.circle",
                        valueColor: .green
                    )
                }
            }

            ForEach(
                Array(sortedAccounts.enumerated()),
                id: \.element.id
            ) { _, account in
                Section {
                    WatchAccountQuotaDetail(
                        account: account,
                        providerColor: providerColor
                    )
                } header: {
                    Text(
                        watchAccountLabel(
                            account,
                            in: sortedAccounts
                        )
                    )
                    .lineLimit(1)
                }
            }
        }
        .navigationTitle(provider.provider)
    }
}

struct WatchAccountQuotaDetail: View {
    let account: ProviderAccountUsage
    let providerColor: Color

    private var planLabel: String {
        account.planEvidence.displayValue
            ?? account.planEvidence.rawValue
            ?? L10n.providers.planUnconfirmed
    }

    private var validTiers: [TierDTO] {
        account.tiers.filter { $0.quota > 0 }
    }

    private var isStale: Bool {
        ProviderAccountPresentation.isStale(account)
    }

    var body: some View {
        HStack(spacing: 4) {
            Text(planLabel)
                .lineLimit(1)
            Spacer()
            Text(
                L10n.providers.planSource(
                    account.planEvidence.source
                )
            )
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
        .font(.caption2)

        WatchAccountFreshnessLabel(account: account)

        if !validTiers.isEmpty {
            ForEach(
                Array(validTiers.enumerated()),
                id: \.offset
            ) { _, tier in
                UsageBar(
                    label: tier.name,
                    value: WatchRingMath.remainingFraction(
                        quota: tier.quota,
                        remaining: tier.remaining
                    ),
                    color:
                        isStale
                            ? .gray
                            : QuotaTierStyle.color(
                                quota: tier.quota,
                                remaining: tier.remaining,
                                base: providerColor
                            ),
                    detail: tierDetail(tier)
                )
            }
        } else if let quota = account.quota,
                  quota > 0,
                  let remaining = account.remaining {
            UsageBar(
                label: L10n.providers.quota,
                value: WatchRingMath.remainingFraction(
                    quota: quota,
                    remaining: remaining
                ),
                color:
                    isStale
                        ? .gray
                        : QuotaTierStyle.color(
                            quota: quota,
                            remaining: remaining,
                            base: providerColor
                        ),
                detail: quotaDetail(
                    quota: quota,
                    remaining: remaining,
                    resetTime: account.resetTime
                )
            )
        } else {
            Text(account.statusText)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private func tierDetail(_ tier: TierDTO) -> String {
        quotaDetail(
            quota: tier.quota,
            remaining: tier.remaining,
            resetTime: tier.reset_time
        )
    }

    private func quotaDetail(
        quota: Int,
        remaining: Int,
        resetTime: String?
    ) -> String {
        var result = L10n.watch.percentLeft(
            WatchRingMath.remainingPercentInt(
                quota: quota,
                remaining: remaining
            )
        )
        if let resetTime,
           let reset = RelativeTime.formatReset(resetTime) {
            result += " · \(reset)"
        }
        return result
    }
}

// MARK: - Provider Detail (relocated from the retired WatchProvidersView)

struct WatchProviderDetailView: View {
    let provider: ProviderUsage
    let account: ProviderAccountUsage?
    let showCost: Bool

    private var providerColor: Color {
        PulseTheme.providerColor(provider.provider)
    }

    private var isStale: Bool {
        account.map {
            ProviderAccountPresentation.isStale($0)
        } ?? false
    }

    private var displayedTiers: [TierDTO] {
        if let account { return account.tiers }
        return provider.tiers
    }

    private var displayedQuota: Int? {
        if let account { return account.quota }
        return provider.quota
    }

    private var displayedRemaining: Int? {
        if let account { return account.remaining }
        return provider.remaining
    }

    private var quotaSnapshot: WatchProviderQuotaSnapshot? {
        WatchRingMath.quotaSnapshot(
            for: provider,
            accounts: account.map { [$0] } ?? []
        )
    }

    private var quotaColor: Color {
        guard !isStale, let quotaSnapshot else {
            return .gray
        }
        return WatchTheme.tierColor(
            WatchRingMath.tier(
                usagePercent: quotaSnapshot.usagePercent
            ),
            base: providerColor
        )
    }

    var body: some View {
        List {
            Section {
                HStack(spacing: 8) {
                    Image(systemName: provider.providerKind?.iconName ?? "cpu")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(providerColor)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(provider.provider)
                            .font(.headline)
                        if let account {
                            Text(
                                watchAccountLabel(
                                    account,
                                    in: [account]
                                )
                            )
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        }
                        if let quotaSnapshot {
                            Text(
                                "\(quotaSnapshot.remainingPercent)% "
                                    + L10n.watch.remaining
                            )
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                if let account {
                    HStack(spacing: 4) {
                        Text(
                            account.planEvidence.displayValue
                                ?? account.planEvidence.rawValue
                                ?? L10n.providers.planUnconfirmed
                        )
                        .lineLimit(1)
                        Spacer()
                        Text(
                            L10n.providers.planSource(
                                account.planEvidence.source
                            )
                        )
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    }
                    .font(.caption2)

                    WatchAccountFreshnessLabel(
                        account: account
                    )
                }
            }

            // Quota — per-window bars (remaining/countdown) like macOS/iOS,
            // or the overall gauge when the provider reports no tiers.
            if !displayedTiers.isEmpty {
                Section(L10n.providers.quota) {
                    ForEach(displayedTiers.indices, id: \.self) { i in
                        let tier = displayedTiers[i]
                        UsageBar(
                            label: tier.name,
                            value: WatchRingMath.remainingFraction(quota: tier.quota, remaining: tier.remaining),
                            color:
                                isStale
                                    ? .gray
                                    : QuotaTierStyle.color(
                                        quota: tier.quota,
                                        remaining: tier.remaining,
                                        base: providerColor
                                    ),
                            detail: tierDetail(tier),
                            markers:
                                isStale
                                    ? []
                                    : watchPaceMarkers(tier)
                        )
                    }
                }
            } else if let quotaSnapshot {
                Section(L10n.providers.quota) {
                    Gauge(value: quotaSnapshot.remainingFraction) {
                        Text(provider.provider)
                    } currentValueLabel: {
                        Text("\(quotaSnapshot.remainingPercent)%")
                            .font(.caption.weight(.bold))
                    } minimumValueLabel: {
                        Text("0")
                            .font(.system(size: 8))
                    } maximumValueLabel: {
                        Text("100")
                            .font(.system(size: 8))
                    }
                    .gaugeStyle(.linearCapacity)
                    .tint(quotaColor)
                }
            }

            Section(L10n.dashboard.today) {
                WatchMetricRow(
                    label: L10n.widget.usageTitle,
                    // v1.30 F4 — "—" rather than "0" when there's no token data today.
                    value: provider.today_usage > 0 ? CostFormatter.formatUsage(provider.today_usage) : "—",
                    icon: "chart.bar.fill"
                )
                if showCost {
                    WatchMetricRow(
                        label: L10n.dashboard.costToday,
                        value: CostFormatter.format(provider.estimated_cost_today),
                        icon: "dollarsign.circle",
                        valueColor: .green
                    )
                }
                if let quota = displayedQuota {
                    WatchMetricRow(
                        label: L10n.providers.quota,
                        value: CostFormatter.formatUsage(quota),
                        icon: "gauge.with.needle"
                    )
                }
                if let remaining = displayedRemaining {
                    WatchMetricRow(
                        label: L10n.watch.remaining,
                        value: CostFormatter.formatUsage(remaining),
                        icon: "hourglass",
                        valueColor:
                            isStale
                                ? .secondary
                                : remaining
                                    < (displayedQuota ?? Int.max) / 5
                                    ? .red
                                    : .primary
                    )
                }
            }

            Section(L10n.providers.thisWeek) {
                WatchMetricRow(
                    label: L10n.widget.usageTitle,
                    value: CostFormatter.formatUsage(provider.week_usage),
                    icon: "calendar"
                )
                if showCost {
                    WatchMetricRow(
                        label: L10n.dashboard.costToday,
                        value: CostFormatter.format(provider.estimated_cost_week),
                        icon: "dollarsign.circle",
                        valueColor: .green
                    )
                }
            }

            Section(L10n.dashboard.activity) {
                WatchMetricRow(
                    label: L10n.tab.sessions,
                    value: "\(provider.recent_sessions.count)",
                    icon: "terminal"
                )
                if !provider.recent_errors.isEmpty {
                    WatchMetricRow(
                        label: L10n.watch.errors,
                        value: "\(provider.recent_errors.count)",
                        icon: "exclamationmark.triangle",
                        valueColor: .red
                    )
                }
                if !provider.status_text.isEmpty {
                    HStack {
                        Text(L10n.providers.status)
                            .font(.caption)
                        Spacer()
                        Text(provider.status_text)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .navigationTitle(provider.provider)
    }

    /// "38% left · Resets in 2h" — mirrors the macOS `tierDetail`.
    private func tierDetail(_ tier: TierDTO) -> String {
        var s = L10n.watch.percentLeft(WatchRingMath.remainingPercentInt(quota: tier.quota, remaining: tier.remaining))
        if let reset = tier.reset_time, let resetText = RelativeTime.formatReset(reset) {
            s += " · \(resetText)"
        }
        return s
    }
}
