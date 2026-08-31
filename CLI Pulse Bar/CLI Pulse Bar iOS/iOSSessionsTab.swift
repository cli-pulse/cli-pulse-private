import SwiftUI
import CLIPulseCore

struct iOSSessionsTab: View {
    @EnvironmentObject var state: AppState
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var selectedSession: SessionRecord?

    private var isIPad: Bool { horizontalSizeClass == .regular }

    var body: some View {
        Group {
            if isIPad { iPadSessionsView } else { iPhoneSessionsView }
        }
    }

    // MARK: - iPad: Master-Detail

    private var iPadSessionsView: some View {
        NavigationSplitView {
            sessionList
                .navigationTitle(L10n.tab.sessions)
        } detail: {
            if let session = selectedSession {
                SessionDetailView(session: session, showCost: state.showCost)
            } else {
                ContentUnavailableView {
                    Label(L10n.sessions.select, systemImage: "terminal")
                } description: {
                    Text(L10n.sessions.selectHint)
                }
            }
        }
        .refreshable {
            await state.refreshAll()
        }
    }

    // MARK: - iPhone

    private var iPhoneSessionsView: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 12) {
                    analyticsSection
                }
                .padding()
            }
            .navigationTitle(L10n.tab.sessions)
            .navigationDestination(for: SessionRecord.self) { session in
                SessionDetailView(session: session, showCost: state.showCost)
            }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    // Source of truth = FreshnessTier classifier so the
                    // running pill matches the row badges (only proc-
                    // confirmed rows count as "running"; JSONL-synthesized
                    // rows are "recent activity" / "recent" and don't
                    // contribute).
                    let now = Date()
                    let runningCount = state.sessions.reduce(0) { acc, s in
                        acc + (SessionFreshnessTierClassifier.classify(s, now: now) == .activeProcess ? 1 : 0)
                    }
                    if runningCount > 0 {
                        StatusBadge(text: L10n.sessions.countRunning(runningCount), color: .green)
                    }
                }
            }
            .refreshable {
                await state.refreshAll()
            }
        }
    }

    // MARK: - Analytics sessions

    @ViewBuilder
    private var analyticsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L10n.tab.sessions)
                .font(.headline)
            if state.sessions.isEmpty {
                ContentUnavailableView {
                    Label(L10n.sessions.noSessions, systemImage: "terminal")
                } description: {
                    Text(L10n.sessions.emptyHint)
                }
                .padding(.vertical, 20)
            } else {
                let now = Date()
                let buckets = SessionFreshnessTierClassifier.partition(
                    state.sessions, now: now
                )
                if !buckets.active.isEmpty {
                    iosSessionSection(
                        header: "Active",
                        sessions: buckets.active,
                        now: now
                    )
                }
                if !buckets.recent.isEmpty {
                    iosSessionSection(
                        header: "Recent · last 30 min",
                        sessions: buckets.recent,
                        now: now
                    )
                }
                if buckets.active.isEmpty && buckets.recent.isEmpty {
                    ContentUnavailableView {
                        Label(L10n.sessions.noSessions, systemImage: "terminal")
                    } description: {
                        Text(L10n.sessions.emptyHint)
                    }
                    .padding(.vertical, 20)
                }
                Text("Running = process confirmed. Recent = JSONL activity only.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func iosSessionSection(
        header: String,
        sessions: [SessionRecord],
        now: Date
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(header)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text("· \(sessions.count)")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                Spacer()
            }
            ForEach(sessions) { session in
                let tier = SessionFreshnessTierClassifier.classify(session, now: now)
                NavigationLink(value: session) {
                    iOSSessionRow(
                        session: session,
                        showCost: state.showCost,
                        freshnessTier: tier
                    )
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - iPad list (combined)

    private var sessionList: some View {
        List {
            Section(L10n.tab.sessions) {
                ForEach(state.sessions) { session in
                    HStack(spacing: 10) {
                        Image(systemName: session.providerKind?.iconName ?? "terminal")
                            .foregroundStyle(PulseTheme.providerColor(session.provider))
                            .frame(width: 24)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(session.name)
                                .font(.subheadline.weight(.medium))
                                .lineLimit(1)
                            HStack(spacing: 6) {
                                Text(session.provider).font(.caption2)
                                Text(session.project).font(.caption2)
                            }
                            .foregroundStyle(.secondary)
                        }
                        Spacer()
                        StatusBadge(
                            text: L10n.status.localized(session.status),
                            color: PulseTheme.statusColor(session.status)
                        )
                    }
                    .padding(.vertical, 2)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        selectedSession = session
                    }
                    .listRowBackground(
                        selectedSession?.id == session.id
                            ? Color.accentColor.opacity(0.12)
                            : Color.clear
                    )
                }
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                // Same FreshnessTier source as the iPhone toolbar — only
                // proc-confirmed rows count as "running" in the pill.
                let now = Date()
                let runningTierCount = state.sessions.reduce(0) { acc, s in
                    acc + (SessionFreshnessTierClassifier.classify(s, now: now) == .activeProcess ? 1 : 0)
                }
                let running = runningTierCount
                if running > 0 {
                    StatusBadge(text: L10n.sessions.countRunning(running), color: .green)
                }
            }
        }
    }

    // MARK: - Helpers


}

// MARK: - Managed session detail (iOS)


// MARK: - Session Detail View (existing analytics view, unchanged)

struct SessionDetailView: View {
    let session: SessionRecord
    let showCost: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // Header
                HStack(spacing: 12) {
                    Image(systemName: session.providerKind?.iconName ?? "terminal")
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(PulseTheme.providerColor(session.provider))
                        .frame(width: 48, height: 48)
                        .background(PulseTheme.providerColor(session.provider).opacity(0.12))
                        .clipShape(RoundedRectangle(cornerRadius: 10))

                    VStack(alignment: .leading, spacing: 4) {
                        Text(session.name)
                            .font(.title3.weight(.bold))
                        HStack(spacing: 6) {
                            StatusBadge(
                                text: session.status,
                                color: PulseTheme.statusColor(session.status)
                            )
                            if let conf = session.collection_confidence {
                                ConfidenceBadge(confidence: conf)
                            }
                            CostStatusBadge(status: session.cost_status)
                        }
                    }
                    Spacer()
                }

                // Info grid
                LazyVGrid(columns: [
                    GridItem(.flexible()),
                    GridItem(.flexible()),
                ], spacing: 16) {
                    detailItem(label: L10n.detail.provider, value: session.provider, icon: "cpu")
                    detailItem(label: L10n.detail.project, value: session.project, icon: "folder")
                    detailItem(label: L10n.detail.device, value: session.device_name, icon: "desktopcomputer")
                    detailItem(label: L10n.detail.started, value: RelativeTime.format(session.started_at), icon: "clock")
                }

                Divider()

                // Metrics
                LazyVGrid(columns: [
                    GridItem(.flexible()),
                    GridItem(.flexible()),
                    GridItem(.flexible()),
                ], spacing: 16) {
                    metricBox(title: L10n.detail.usage, value: CostFormatter.formatUsage(session.total_usage))
                    if showCost {
                        metricBox(title: L10n.detail.cost, value: CostFormatter.format(session.estimated_cost), color: .green)
                    }
                    metricBox(title: L10n.detail.requests, value: "\(session.requests)")
                    if session.error_count > 0 {
                        metricBox(title: L10n.detail.errors, value: "\(session.error_count)", color: .red)
                    }
                }
            }
            .padding(24)
        }
        .navigationTitle(session.name)
        .navigationBarTitleDisplayMode(.inline)
    }

    private func detailItem(label: String, value: String, icon: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(label)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Text(value)
                    .font(.subheadline.weight(.medium))
            }
            Spacer()
        }
    }

    private func metricBox(title: String, value: String, color: Color = .primary) -> some View {
        VStack(spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.title2.weight(.bold).monospacedDigit())
                .foregroundStyle(color)
        }
        .frame(maxWidth: .infinity)
        .padding()
        .background(PulseTheme.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}

// MARK: - Session Row (iPhone, unchanged)

struct iOSSessionRow: View {
    let session: SessionRecord
    let showCost: Bool
    /// Optional Active/Recent tier badge. Nil when this row is
    /// rendered outside the analytics section split (legacy callers).
    let freshnessTier: FreshnessTier?

    init(session: SessionRecord, showCost: Bool, freshnessTier: FreshnessTier? = nil) {
        self.session = session
        self.showCost = showCost
        self.freshnessTier = freshnessTier
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: session.providerKind?.iconName ?? "terminal")
                    .foregroundStyle(PulseTheme.providerColor(session.provider))

                Text(session.displayName)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)

                Spacer()

                // One badge per row — see SessionsTab.swift macOS for
                // rationale. Process-confirmed rows keep the
                // localized "running" status pill; JSONL-only rows
                // (activeJsonl / recentJsonl) drop the status pill
                // and show only the freshness chip so we don't
                // over-claim "running" when we only know JSONL mtime.
                if let tier = freshnessTier, tier.isVisible {
                    if tier == .activeProcess {
                        StatusBadge(
                            text: L10n.status.localized(session.status),
                            color: PulseTheme.statusColor(session.status)
                        )
                    } else {
                        StatusBadge(text: tier.badge, color: tierColor(tier))
                    }
                } else {
                    StatusBadge(
                        text: L10n.status.localized(session.status),
                        color: PulseTheme.statusColor(session.status)
                    )
                }
            }

            HStack(spacing: 14) {
                Label(session.provider, systemImage: "cpu")
                Label(session.project, systemImage: "folder")
                if let conf = session.collection_confidence {
                    ConfidenceBadge(confidence: conf)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)

            HStack(spacing: 18) {
                // Same gate as macOS: proc-* rows have heuristic
                // metrics that mislead at long uptimes. Hide the
                // trio for those rows; tier badge tells the story.
                if !session.hasProcessHeuristicMetrics {
                    metricItem(label: L10n.detail.usage, value: CostFormatter.formatUsage(session.total_usage))
                    if showCost {
                        metricItem(label: L10n.detail.cost, value: CostFormatter.format(session.estimated_cost), color: .green)
                    }
                    if session.hasMeaningfulRequestCount {
                        metricItem(label: L10n.detail.requests, value: "\(session.requests)")
                    }
                }
                if session.error_count > 0 {
                    metricItem(label: L10n.detail.errors, value: "\(session.error_count)", color: .red)
                }
                Spacer()
                Text(RelativeTime.format(session.last_active_at))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(12)
        .background(PulseTheme.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(
                    session.status.caseInsensitiveCompare("failed") == .orderedSame ? Color.red.opacity(0.3) :
                    PulseTheme.providerColor(session.provider).opacity(0.15),
                    lineWidth: 1
                )
        )
    }

    private func metricItem(label: String, value: String, color: Color = .primary) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.tertiary)
            Text(value)
                .font(.subheadline.weight(.bold).monospacedDigit())
                .foregroundStyle(color)
        }
    }

    private func tierColor(_ tier: FreshnessTier) -> Color {
        switch tier {
        case .activeProcess: return .green
        case .activeJsonl:   return .blue
        case .recentJsonl:   return .secondary
        case .hidden:        return .clear
        }
    }
}
