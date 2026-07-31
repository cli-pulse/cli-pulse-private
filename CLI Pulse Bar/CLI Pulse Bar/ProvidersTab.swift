import SwiftUI
import CLIPulseCore

struct ProvidersTab: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var providerState: ProviderState
    @State private var showDisabled = false
    @State private var searchText = ""

    private var sortedDetails: [ProviderDetail] {
        providerState.providerDetails.filter { showDisabled || $0.config.isEnabled }
    }

    /// `sortedDetails` narrowed by the search field (name match). Empty query =
    /// all, so search is purely additive over the show-disabled filter.
    private var filteredDetails: [ProviderDetail] {
        sortedDetails.filter {
            ProviderSearchFilter.matches(providerName: $0.provider.provider, query: searchText)
        }
    }

    var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 10) {
                // Header
                HStack {
                    Text(L10n.providers.title)
                        .font(.system(size: 14, weight: .bold))
                    Spacer()
                    Button {
                        showDisabled.toggle()
                    } label: {
                        Text(showDisabled ? L10n.providers.hideDisabled : L10n.providers.showAll)
                            .font(.system(size: 9))
                            .foregroundStyle(PulseTheme.accent)
                    }
                    .buttonStyle(.plain)
                    Text("\(providerState.enabledProviderCount) \(L10n.providers.tracked)")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }

                // Provider name search (CodexBar 0.32 parity) — filters the
                // visible cards as you type.
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                    TextField(L10n.providers.searchPlaceholder, text: $searchText)
                        .textFieldStyle(.plain)
                        .font(.system(size: 11))
                    if !searchText.isEmpty {
                        Button {
                            searchText = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 10))
                                .foregroundStyle(.tertiary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(Color.secondary.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 6))

                // v1.9.4: first-run nudge when the cost scanner came back
                // empty because the App Sandbox hasn't been granted access to
                // `~/.codex/sessions/` / `~/.claude/projects/`. Opens the
                // Settings tab's Folder Access section on click.
                if state.needsScannerFolderAccess {
                    folderAccessBanner
                }

                // Cost summary bar
                if state.showCost {
                    costSummaryBar
                }

                if sortedDetails.isEmpty && providerState.providers.isEmpty {
                    EmptyStateView(
                        icon: "cpu",
                        title: L10n.providers.noProviders,
                        subtitle: L10n.providers.emptyHint
                    )
                } else if sortedDetails.isEmpty {
                    EmptyStateView(
                        icon: "eye.slash",
                        title: L10n.providers.allHidden,
                        subtitle: L10n.providers.showAllHint
                    )
                } else if filteredDetails.isEmpty {
                    EmptyStateView(
                        icon: "magnifyingglass",
                        title: L10n.providers.noSearchMatch,
                        subtitle: ""
                    )
                } else {
                    ForEach(filteredDetails) { detail in
                        let configs = providerState.configs(
                            for: detail.config.kind
                        )
                        EnhancedProviderCard(
                            detail: detail,
                            showCost: state.showCost,
                            accountConfigs: configs,
                            accountUsages:
                                providerState.providerAccounts.filter {
                                    $0.provider == detail.config.kind
                                },
                            onAccountToggle: {
                                accountID,
                                isEnabled in
                                state.setProviderAccountEnabled(
                                    accountID,
                                    isEnabled: isEnabled
                                )
                            }
                        )
                    }
                }
            }
            .padding(12)
        }
    }

    private var folderAccessBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "folder.badge.questionmark")
                .foregroundStyle(.orange)
                .font(.system(size: 14))
            VStack(alignment: .leading, spacing: 2) {
                Text(L10n.providers.grantAccessTitle)
                    .font(.system(size: 11, weight: .semibold))
                Text(L10n.providers.grantAccessBody)
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer()
            Button(L10n.providers.openSettings) {
                state.selectedTab = .settings
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(10)
        .background(Color.orange.opacity(0.12))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.orange.opacity(0.3), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var costSummaryBar: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 1) {
                Text(L10n.dashboard.today)
                    .font(.system(size: 8))
                    .foregroundStyle(.tertiary)
                Text(CostFormatter.format(providerState.costSummary.todayTotal))
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundStyle(.green)
            }
            Divider().frame(height: 24)
            VStack(alignment: .leading, spacing: 1) {
                Text(L10n.dashboard.thirtyDayEst)
                    .font(.system(size: 8))
                    .foregroundStyle(.tertiary)
                Text(CostFormatter.format(providerState.costSummary.thirtyDayTotal))
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundStyle(.green)
            }
            Spacer()
        }
        .padding(8)
        .background(PulseTheme.cardBackground.opacity(0.3))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

struct ProviderAccountQuotaSummaryView: View {
    let provider: ProviderKind
    let configs: [ProviderConfig]
    let usages: [ProviderAccountUsage]
    let showProviderCostNote: Bool
    let showsToggles: Bool
    let onToggle: (UUID, Bool) -> Void

    @State private var isExpanded = false

    private var scopedUsages: [ProviderAccountUsage] {
        let accountIDs = Set(configs.map(\.accountID))
        return usages.filter {
            $0.provider == provider
                && accountIDs.contains($0.id)
        }
    }

    private var mostConstrained: ProviderAccountUsage? {
        ProviderState.mostConstrainedAccount(
            in: scopedUsages,
            enabledAccountIDs: Set(
                configs.filter(\.isEnabled).map(\.accountID)
            )
        )
    }

    var body: some View {
        DisclosureGroup(
            isExpanded: $isExpanded
        ) {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(configs) { config in
                    accountQuotaRow(config)
                }

                if showProviderCostNote {
                    Label(
                        L10n.providers.providerLevelCost,
                        systemImage: "info.circle"
                    )
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(
                        horizontal: false,
                        vertical: true
                    )
                }
            }
            .padding(.top, 7)
            .padding(.leading, 6)
        } label: {
            HStack(spacing: 6) {
                Text(
                    L10n.providers.accountsCount(
                        configs.count
                    )
                )
                .font(.caption.weight(.semibold))

                if let mostConstrained,
                   let fraction =
                    ProviderState.remainingFraction(
                        for: mostConstrained
                    ) {
                    Text(L10n.providers.mostConstrained)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.orange)
                    Text(
                        "\(accountDisplayLabel(for: mostConstrained.id)) · "
                        + L10n.providers.remainingPercent(
                            Int((fraction * 100).rounded())
                        )
                    )
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                }
            }
        }
        .padding(8)
        .background(Color.secondary.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 7))
    }

    private func accountQuotaRow(
        _ config: ProviderConfig
    ) -> some View {
        let usage = scopedUsages.first {
            $0.id == config.accountID
        }
        let plan =
            usage?.planEvidence.displayValue
            ?? config.planOverride
            ?? L10n.providers.planUnconfirmed

        return VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(accountDisplayLabel(for: config.accountID))
                        .font(.caption.weight(.medium))
                        .lineLimit(1)
                    Text(plan)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                if mostConstrained?.id == config.accountID {
                    Text(L10n.providers.mostConstrained)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.orange)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(Color.orange.opacity(0.1))
                        .clipShape(Capsule())
                }

                if !config.isEnabled {
                    Text(L10n.providers.disabledBadge)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                }

                Spacer()

                if showsToggles {
                    Toggle(
                        "",
                        isOn: Binding(
                            get: { config.isEnabled },
                            set: { isEnabled in
                                onToggle(
                                    config.accountID,
                                    isEnabled
                                )
                            }
                        )
                    )
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .accessibilityLabel(
                        L10n.providers.monitorAccount(
                            accountDisplayLabel(
                                for: config.accountID
                            )
                        )
                    )
                }
            }

            accountQuotaContent(usage)
        }
        .padding(7)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    @ViewBuilder
    private func accountQuotaContent(
        _ usage: ProviderAccountUsage?
    ) -> some View {
        if let usage {
            let validTiers = usage.tiers.filter { $0.quota > 0 }
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
                        detail:
                            "\(tier.remaining) / \(tier.quota)"
                    )
                }
            } else if let quota = usage.quota,
                      quota > 0,
                      let remaining = usage.remaining {
                let fraction = remainingFraction(
                    remaining: remaining,
                    quota: quota
                )
                UsageBar(
                    label: L10n.providers.quota,
                    value: fraction,
                    color: quotaColor(fraction),
                    detail: "\(remaining) / \(quota)"
                )
            } else {
                Text(usage.statusText)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        } else {
            Text(L10n.providers.needsReconnect)
                .font(.caption2)
                .foregroundStyle(.orange)
        }
    }

    private func accountDisplayLabel(
        for accountID: UUID
    ) -> String {
        let usage = scopedUsages.first { $0.id == accountID }
        if let label = usage?.accountLabel?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !label.isEmpty {
            return label
        }
        if let label = configs.first(where: {
            $0.accountID == accountID
        })?.accountLabel?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !label.isEmpty {
            return label
        }
        guard configs.count > 1,
              let index = configs.firstIndex(where: {
                  $0.accountID == accountID
              })
        else {
            return L10n.providers.defaultAccount
        }
        return L10n.providers.accountNumber(index + 1)
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
        if remainingFraction <= 0.1 {
            return .red
        }
        if remainingFraction <= 0.25 {
            return .orange
        }
        return PulseTheme.providerColor(provider.rawValue)
    }
}

// MARK: - Enhanced Provider Card

struct EnhancedProviderCard: View {
    let detail: ProviderDetail
    let showCost: Bool
    let accountConfigs: [ProviderConfig]
    let accountUsages: [ProviderAccountUsage]
    let onAccountToggle: (UUID, Bool) -> Void

    @EnvironmentObject var state: AppState

    private var provider: ProviderUsage { detail.provider }
    private var config: ProviderConfig { detail.config }

    /// v1.9.4: for quota providers (Claude / Codex / Cursor / ...), the raw
    /// `today_usage` / `week_usage` int fields on `ProviderUsage` carry the
    /// utilization % (0-100), not tokens. Displaying that raw number next to
    /// the label "Today" is misleading — "37" looked like a token count.
    /// Prefer real token counts from the JSONL scan when available.
    private var isQuotaProvider: Bool { provider.metadata?.supports_quota ?? false }

    @ViewBuilder
    private func usageColumn(header: String, metric: CardMetric, cost: Double) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(header)
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
            Text(metric.primary)
                .font(.system(size: 14, weight: .bold, design: .rounded))
                .help(metric.breakdownTooltip)
            if let sub = metric.secondary {
                Text(sub)
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                    .help(metric.breakdownTooltip)
            }
            if showCost {
                Text(CostFormatter.format(cost))
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.green)
            }
        }
    }

    /// v1.9.4 display model:
    /// - `primary`: the headline number + unit label shown big.
    /// - `secondary`: optional smaller line below (e.g. I/O token count for Claude).
    /// - `breakdownTooltip`: long-form hover help text.
    ///
    /// Claude leads with deduped assistant-message count because Claude Code's
    /// own UI does and raw tokens are drowned in ~98% cache_read noise.
    /// Codex leads with I/O tokens to match OpenAI's dashboard convention.
    private struct CardMetric {
        let primary: String           // e.g. "234 msgs" or "3.1M I/O tokens"
        let secondary: String?        // e.g. "320K I/O tokens"
        let breakdownTooltip: String
    }

    private var isClaude: Bool { provider.provider == "Claude" }

    private func metric(for date: Date?, weekRolling: Bool = false) -> CardMetric {
        let msgs: Int? = {
            if weekRolling { return state.scanMessagesThisWeek(for: provider.provider) }
            return state.scanMessages(for: provider.provider, onDate: date ?? Date())
        }()
        let tokens: Int? = {
            if weekRolling { return state.scanTokensThisWeek(for: provider.provider) }
            return state.scanTokens(for: provider.provider, onDate: date ?? Date())
        }()

        if isClaude {
            if let msgs {
                return CardMetric(
                    primary: "\(CostFormatter.formatUsage(msgs)) msgs",
                    secondary: tokens.map { "\(CostFormatter.formatUsage($0)) I/O" },
                    breakdownTooltip: "Messages = user + assistant log events (including streaming chunks) — matches Claude Code's UI convention. I/O tokens = input + output (excludes cache reads, which are ~98% of Claude's raw token volume, and are billed at a 10% discount)."
                )
            }
            if isQuotaProvider {
                return CardMetric(primary: "—", secondary: nil,
                                  breakdownTooltip: "No local Claude scan data for this window yet. Grant access in Settings → CLI Tool Access, then click Force Rescan.")
            }
        }

        // Codex and other quota providers: lead with I/O tokens
        if isQuotaProvider {
            if let tokens {
                return CardMetric(
                    primary: "\(CostFormatter.formatUsage(tokens)) I/O",
                    secondary: nil,
                    breakdownTooltip: "Input + output tokens only (matches OpenAI billing convention). Excludes cached input which is billed at 10% rate."
                )
            }
            return CardMetric(primary: "—", secondary: nil,
                              breakdownTooltip: "No local scan data for this window yet.")
        }

        // Non-quota providers: token count stored in today_usage/week_usage.
        let raw = weekRolling ? provider.week_usage : provider.today_usage
        return CardMetric(
            primary: CostFormatter.formatUsage(raw),
            secondary: nil,
            breakdownTooltip: "Token count reported by the provider's API."
        )
    }

    /// v1.44 W3: collector outcome + one next step, or nothing at all.
    ///
    /// Deliberately silent for `.producedData`: a provider that is working
    /// should not spend a line of a dense card saying so. `.disabled` is
    /// silent too — the DISABLED badge in the header already covers it, and
    /// repeating it here would nag the user about their own deliberate choice.
    @ViewBuilder
    private var collectorOutcomeRow: some View {
        if let kind = ProviderKind(rawValue: provider.provider),
           let outcome = state.collectorOutcomes[kind],
           outcome != .producedData,
           outcome != .disabled {
            let presentation = CollectorOutcomePresentation.of(outcome, providerName: provider.provider)
            HStack(alignment: .top, spacing: 5) {
                Image(systemName: outcomeIcon(presentation.severity))
                    .font(.system(size: 9))
                    .foregroundStyle(outcomeTint(presentation.severity))
                VStack(alignment: .leading, spacing: 1) {
                    Text(presentation.label)
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(outcomeTint(presentation.severity))
                    if let step = presentation.nextStep {
                        Text(step)
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 5)
            .background(outcomeTint(presentation.severity).opacity(0.10))
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
    }

    private func outcomeTint(_ severity: CollectorOutcomePresentation.Severity) -> Color {
        switch severity {
        case .normal: return .secondary
        case .attention: return .orange
        case .problem: return .red
        }
    }

    private func outcomeIcon(_ severity: CollectorOutcomePresentation.Severity) -> String {
        switch severity {
        case .normal: return "info.circle"
        case .attention: return "exclamationmark.triangle"
        case .problem: return "xmark.octagon"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Header row
            HStack(spacing: 8) {
                providerIcon
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 4) {
                        Text(provider.provider)
                            .font(.system(size: 12, weight: .bold))
                        if !config.isEnabled {
                            Text(L10n.providers.disabledBadge)
                                .font(.system(size: 7, weight: .bold))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background(Color.gray.opacity(0.15))
                                .clipShape(Capsule())
                        }
                    }
                    HStack(spacing: 4) {
                        // Status indicator
                        Circle()
                            .fill(statusColor)
                            .frame(width: 5, height: 5)
                        Text(statusText)
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                        if let src = detail.version {
                            Text("v\(src)")
                                .font(.system(size: 8))
                                .foregroundStyle(.quaternary)
                        }
                        // Provider service-status (incident/maintenance) — renders
                        // nothing unless this provider's status page reports an issue.
                        if let kind = ProviderKind(rawValue: provider.provider) {
                            ServiceStatusBadge(provider: kind)
                        }
                    }
                }
                Spacer()

                if accountConfigs.count == 1,
                   let accountID = accountConfigs.first?.accountID {
                    Toggle(
                        "",
                        isOn: Binding(
                            get: { config.isEnabled },
                            set: { newValue in
                                onAccountToggle(
                                    accountID,
                                    newValue
                                )
                            }
                        )
                    )
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .labelsHidden()
                    .animation(
                        .easeInOut(duration: 0.15),
                        value: config.isEnabled
                    )
                    .accessibilityLabel(
                        L10n.providers.monitorAccount(
                            accountConfigs.first?
                                .accountLabel
                                ?? config.kind.rawValue
                        )
                    )
                } else if accountConfigs.count > 1 {
                    Text(
                        L10n.providers.accountsCount(
                            accountConfigs.count
                        )
                    )
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(Color.secondary.opacity(0.1))
                    .clipShape(Capsule())
                }
            }

            // v1.44 W3: what actually happened to this provider's collector.
            //
            // Renders nothing when it produced data — a working provider needs
            // no explanation and the card is already dense. Everything else
            // gets a label and one concrete next step, because the previous
            // behaviour (render nothing, whatever happened) reads to the user
            // as "this tool isn't supported", which is usually false and is
            // the single most expensive wrong conclusion available here.
            collectorOutcomeRow

            // Provider status page — an expandable "Service Status" row listing
            // this provider's service components (● name · Operational) + an
            // "Open Status Page" link. Renders nothing for providers without a
            // known status page; fetches only when expanded.
            if let kind = ProviderKind(rawValue: provider.provider) {
                ProviderStatusComponentsView(provider: kind)
            }

            if accountConfigs.count > 1 {
                ProviderAccountQuotaSummaryView(
                    provider: config.kind,
                    configs: accountConfigs,
                    usages: accountUsages,
                    showProviderCostNote: showCost,
                    showsToggles: true,
                    onToggle: onAccountToggle
                )
            }

            if config.isEnabled {
                // Source + Plan row
                HStack(spacing: 8) {
                    if let email = detail.accountEmail {
                        Label(email, systemImage: "envelope")
                            .font(.system(size: 8))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                    if let plan = detail.planType {
                        StatusBadge(text: plan, color: plan == "Paid" ? .green : .orange)
                    }
                    Text(L10n.providers.sourceLabel(detail.sourceType.rawValue))
                        .font(.system(size: 8))
                        .foregroundStyle(.quaternary)
                    Spacer()
                    quotaBadge
                }

                // Usage stats — v1.9.4 layout:
                //   Today:           This Week:
                //   234 msgs         1,840 msgs        (Claude hero)
                //   320K I/O tokens  2.4M I/O tokens   (Claude sub)
                //   $7.40            $461.20           (cost, always)
                // Codex / other quota providers: primary line is I/O tokens,
                // no sub line. Hover the primary line for a token-breakdown
                // tooltip explaining what's included/excluded.
                let today = metric(for: Date())
                let week = metric(for: nil, weekRolling: true)
                HStack(spacing: 12) {
                    usageColumn(header: "Today", metric: today, cost: provider.estimated_cost_today)
                    usageColumn(header: L10n.providers.thisWeek, metric: week, cost: provider.estimated_cost_week)
                    Spacer()
                }

                // Usage tiers
                if !detail.tiers.isEmpty {
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
                } else if let quota = provider.quota,
                          quota > 0,
                          // v1.9.3: never synthesise an overall bar for Claude
                          // here either — its three-tier model means an empty
                          // tier list signals "data unavailable", not "use the
                          // overall quota" (matches AppState.buildProviderDetails).
                          provider.provider != "Claude" {
                    UsageBar(
                        label: "Quota",
                        value: provider.usagePercent,
                        color: usageColor,
                        detail: remainingText
                    )
                } else if provider.metadata?.supports_quota == true {
                    // Quota provider with no captured data — surface honestly
                    // rather than rendering a misleading "100% left" bar. Use
                    // the collector-supplied `status_text` when it's more
                    // specific than the generic fallback (Claude provides
                    // "Signed in as X — Connect Claude Code in Settings" etc.,
                    // which is more actionable than "/usage in the CLI").
                    let detailText: String = {
                        // iter14: status_text is non-optional `String`,
                        // so `?? ""` was a redundant coalesce that Swift
                        // warns about. Keep the empty-string semantics
                        // (the downstream `s.isEmpty` check handles the
                        // collector-omitted case) by reading directly.
                        let s = provider.status_text
                        // Treat generic / stale placeholders as "no guidance";
                        // fall back to a provider-agnostic line. Avoid the old
                        // "/usage in the CLI" hint — that command was removed
                        // in Claude CLI v2.x.
                        if !s.isEmpty && s != "Operational" &&
                           !s.lowercased().contains("try `/usage`") {
                            return s
                        }
                        return L10n.providers.quotaDataUnavailable
                    }()
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(.orange.opacity(0.7))
                        Text(detailText)
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    .padding(.vertical, 2)
                }

                // Recent sessions
                if !provider.recent_sessions.isEmpty {
                    HStack(spacing: 4) {
                        Image(systemName: "terminal")
                            .font(.system(size: 8))
                            .foregroundStyle(.tertiary)
                        Text(provider.recent_sessions.prefix(3).joined(separator: ", "))
                            .font(.system(size: 9))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                }

                // v1.23 G4: CodexBar-parity usage-pace forecast
                // ("12% in deficit · runs out in 3d"). Engine-gated to
                // Codex/Claude with a valid future reset anchor; nil ⇒
                // the row is simply absent. Safe in this vertically-
                // stacked card list (Gemini R1 CRITICAL applies only to
                // equal-height grids/HStacks — verified inapplicable).
                if let paceSummary = provider.paceSummary() {
                    HStack(spacing: 4) {
                        Image(systemName: "gauge.with.needle")
                            .font(.system(size: 8))
                            .foregroundStyle(.tertiary)
                        Text(paceSummary)
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }

                // v1.30 F3 — per-provider daily usage history (last 30 days),
                // shown only when there's history. Data is already cached on
                // AppState.dailyUsage (no extra fetch).
                let usageHistory = ProviderUsageHistory.series(from: state.dailyUsage, provider: provider.provider)
                if usageHistory.contains(where: { $0.ioTokens > 0 }) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L10n.widget.usageTitle)
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(.secondary)
                        ProviderUsageHistoryChart(points: usageHistory, accent: providerColor)
                    }
                    .padding(.top, 2)
                }
            }
        }
        .padding(10)
        .background(PulseTheme.cardBackground.opacity(config.isEnabled ? 0.5 : 0.2))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(providerColor.opacity(config.isEnabled ? 0.2 : 0.05), lineWidth: 1)
        )
        .opacity(config.isEnabled ? 1.0 : 0.6)
        // v1.10 P3-3: VoiceOver summary when the card is focused.
        // `.contain` so nested UsageBars keep their own drill-in accessibility.
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilitySummary)
    }

    private var accessibilitySummary: String {
        var parts: [String] = [provider.provider]
        parts.append(config.isEnabled ? "enabled" : "disabled")
        parts.append(provider.status_text)
        if let quota = provider.quota, quota > 0 {
            let pct = Int(round(provider.usagePercent * 100))
            parts.append("\(pct)% used")
        }
        return parts.joined(separator: ", ")
    }

    private var providerColor: Color {
        PulseTheme.providerColor(provider.provider)
    }

    private var statusColor: Color {
        switch detail.operationalStatus {
        case .operational: return .green
        case .degraded: return .orange
        case .down: return .red
        }
    }

    private var statusText: String {
        if !config.isEnabled { return "Disabled" }
        switch detail.operationalStatus {
        case .operational: return "Operational"
        case .degraded: return "Degraded"
        case .down: return "Down"
        }
    }

    private var providerIcon: some View {
        Image(systemName: config.kind.iconName)
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(providerColor)
            .frame(width: 28, height: 28)
            .background(providerColor.opacity(0.12))
            .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private var usageColor: Color {
        if provider.usagePercent > 0.9 { return .red }
        if provider.usagePercent > 0.7 { return .orange }
        return providerColor
    }

    /// v1.30 F2 — expected-pace marker + configured warning-threshold ticks for
    /// a tier bar. Tier bars render `value: 1 - usagePercent`
    /// (remaining-oriented), so every as-used fraction is placed via
    /// `onRemainingBar: true`.
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

    private var remainingText: String? {
        guard let remaining = provider.remaining else { return nil }
        return "\(CostFormatter.formatUsage(remaining)) remaining"
    }

    private var quotaBadge: some View {
        Group {
            if provider.usagePercent > 0.9 {
                StatusBadge(text: "LOW", color: .red)
            } else if provider.usagePercent > 0.7 {
                StatusBadge(text: "MODERATE", color: .orange)
            } else {
                StatusBadge(text: "OK", color: .green)
            }
        }
    }
}
