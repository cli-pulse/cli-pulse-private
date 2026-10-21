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
                SessionDetailView(session: session, showCost: state.showCost, now: state.sessionsClock())
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
        #if DEBUG
        .task {
            // App Store capture: a session open beside the list, as after a
            // tap (ScreenshotLaunch.Screen.opensSessionDetail).
            if selectedSession == nil, ScreenshotLaunch.activeRequest?.screen.opensSessionDetail == true {
                selectedSession = ScreenshotLaunch.sessionToOpen(in: state.sessions, now: state.sessionsClock())
            }
        }
        #endif
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
                SessionDetailView(session: session, showCost: state.showCost, now: state.sessionsClock())
            }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    // Source of truth = FreshnessTier classifier so the
                    // running pill matches the row badges (only process-
                    // confirmed rows, `local-` and `proc-`, count as
                    // "running"; JSONL-synthesized rows are "recent
                    // activity" / "recent" and don't contribute).
                    let now = state.sessionsClock()
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
        // No "Sessions" headline: the navigation title right above already
        // says it, and the Active and Recent headers lead the list.
        VStack(alignment: .leading, spacing: 8) {
            if state.sessions.isEmpty {
                ContentUnavailableView {
                    Label(L10n.sessions.noSessions, systemImage: "terminal")
                } description: {
                    Text(L10n.sessions.emptyHint)
                }
                .padding(.vertical, 20)
            } else {
                let now = state.sessionsClock()
                let buckets = SessionFreshnessTierClassifier.partition(
                    state.sessions, now: now
                )
                if !buckets.active.isEmpty {
                    iosSessionSection(
                        header: L10n.sessions.sectionActive,
                        sessions: buckets.active,
                        now: now
                    )
                }
                if !buckets.recent.isEmpty {
                    iosSessionSection(
                        header: L10n.sessions.sectionRecent,
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
                // v1.58: one line for each badge a row shows; since 1.57
                // every synced row reads "Running".
                if let legend = SessionFreshnessLegend.text(for: state.sessions, now: now) {
                    Text(legend)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
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

    // MARK: - iPad list

    /// The iPhone's Active and Recent sections (SessionFreshnessTierClassifier),
    /// with the iPhone row's badge. Until 1.55 this list drew every session in
    /// one untitled section with its raw status, so all of Demo's five read
    /// "Running" beside the sidebar's "Active Sessions 3", while the iPhone
    /// put two of them under Recent and keeps "Running" for process-confirmed
    /// rows (the legend below says so).
    private var sessionList: some View {
        let now = state.sessionsClock()
        let buckets = SessionFreshnessTierClassifier.partition(state.sessions, now: now)
        // v1.58: one line for each badge a row shows.
        let legend = SessionFreshnessLegend.text(for: state.sessions, now: now)
        return List {
            // The legend the iPhone shows under its list, under the last section.
            if !buckets.active.isEmpty {
                iPadSessionSection(header: L10n.sessions.sectionActive, sessions: buckets.active, now: now,
                                   legend: buckets.recent.isEmpty ? legend : nil)
            }
            if !buckets.recent.isEmpty {
                iPadSessionSection(header: L10n.sessions.sectionRecent, sessions: buckets.recent, now: now,
                                   legend: legend)
            }
        }
        // Wide enough for a session's name and project beside its badge; at
        // the default width every row was cut short ("helper-heart…"). The
        // split view gives this column its minimum on the 13-inch iPad in
        // portrait, so the minimum is the width that fits.
        .navigationSplitViewColumnWidth(min: 360, ideal: 360, max: 420)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                // Same FreshnessTier source as the iPhone toolbar — only
                // process-confirmed rows (`local-` and `proc-`) count as
                // "running" in the pill.
                let now = state.sessionsClock()
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

    private func iPadSessionSection(header: String, sessions: [SessionRecord], now: Date,
                                    legend: String?) -> some View {
        Section {
            ForEach(sessions) { session in
                HStack(spacing: 10) {
                    Image(systemName: session.providerKind?.iconName ?? "terminal")
                        .foregroundStyle(PulseTheme.providerColor(session.provider))
                        .frame(width: 24)
                    VStack(alignment: .leading, spacing: 2) {
                        // The iPhone row's title: a process-scan row's
                        // provider and project, not its command line. Two
                        // lines: beside "En ejecución" one line cut
                        // "Gemini · cli-pulse-helper" short.
                        Text(session.displayName)
                            .font(.subheadline.weight(.medium))
                            .lineLimit(2)
                        // One line: beside a long badge ("En ejecución") the
                        // project used to break into three hyphenated lines.
                        // A scan row's title already names its provider and
                        // project, so its line names the device instead.
                        HStack(spacing: 6) {
                            if session.titleNamesProviderAndProject {
                                Text(session.device_name).font(.caption2)
                                    .lineLimit(1)
                            } else {
                                Text(session.provider).font(.caption2)
                                    .fixedSize()
                                if let project = session.displayProject {
                                    Text(project).font(.caption2)
                                        .lineLimit(1)
                                }
                            }
                        }
                        .foregroundStyle(.secondary)
                    }
                    Spacer()
                    SessionStatusBadge(
                        session: session,
                        tier: SessionFreshnessTierClassifier.classify(session, now: now)
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
        } header: {
            // The iPhone section header: the title and its count.
            HStack(spacing: 4) {
                Text(header)
                Text("· \(sessions.count)")
                    .foregroundStyle(.tertiary)
            }
        } footer: {
            if let legend {
                Text(legend)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// A session's one badge, the same in the iPhone's rows, the iPad's list and
/// the detail either opens. A process-confirmed row (or one outside both
/// sections) shows its status, "Running"; a row known only from recent log
/// writes shows its freshness tier ("Recent activity", "Recent") instead, so
/// nothing claims a process is running when only a log was written.
struct SessionStatusBadge: View {
    let session: SessionRecord
    let tier: FreshnessTier?

    var body: some View {
        if let tier, tier.isVisible, tier != .activeProcess {
            StatusBadge(text: tier.badge, color: Self.color(tier))
        } else {
            StatusBadge(
                text: L10n.status.localized(session.status),
                color: PulseTheme.statusColor(session.status)
            )
        }
    }

    static func color(_ tier: FreshnessTier) -> Color {
        switch tier {
        case .activeProcess: return .green
        case .activeJsonl:   return .blue
        case .recentJsonl:   return .secondary
        case .hidden:        return .clear
        }
    }
}

// MARK: - Managed session detail (iOS)


// MARK: - Session Detail View

/// A session's detail: the iPhone pushes it, the iPad shows it beside the list.
/// It follows the row: the row's title (`displayName`), its badge, and for a
/// process-scan row none of the usage, cost or requests the row hides
/// (`SessionRecord.hasProcessHeuristicMetrics`), nor the cost badge that
/// describes them. Those figures are runtime x a formula, not usage.
struct SessionDetailView: View {
    let session: SessionRecord
    let showCost: Bool
    /// The moment its badge is classified at: the list's
    /// (`AppState.sessionsClock`), so in Demo it matches the row tapped.
    var now = Date()

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
                        Text(session.displayName)
                            .font(.title3.weight(.bold))
                        HStack(spacing: 6) {
                            // The badge the session's row shows: on iPad the
                            // row and this header sit side by side.
                            SessionStatusBadge(
                                session: session,
                                tier: SessionFreshnessTierClassifier.classify(session, now: now)
                            )
                            if let conf = session.collection_confidence {
                                ConfidenceBadge(confidence: conf)
                            }
                            if !session.hasProcessHeuristicMetrics {
                                CostStatusBadge(status: session.cost_status)
                            }
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
                    detailItem(label: L10n.detail.project, value: session.detailProject, icon: "folder")
                    detailItem(label: L10n.detail.device, value: session.device_name, icon: "desktopcomputer")
                    detailItem(label: L10n.detail.started, value: RelativeTime.format(session.started_at), icon: "clock")
                }

                // Metrics, as the row shows them: a process-scan row's are
                // left out, and so is the request count the row leaves out.
                if !session.hasProcessHeuristicMetrics || session.error_count > 0 {
                    Divider()

                    LazyVGrid(columns: [
                        GridItem(.flexible()),
                        GridItem(.flexible()),
                        GridItem(.flexible()),
                    ], spacing: 16) {
                        if !session.hasProcessHeuristicMetrics {
                            metricBox(title: L10n.detail.usage, value: CostFormatter.formatUsage(session.total_usage))
                            if showCost {
                                metricBox(title: L10n.detail.cost, value: CostFormatter.format(session.estimated_cost), color: .green)
                            }
                            if session.hasMeaningfulRequestCount {
                                metricBox(title: L10n.detail.requests, value: "\(session.requests)")
                            }
                        }
                        if session.error_count > 0 {
                            metricBox(title: L10n.detail.errors, value: "\(session.error_count)", color: .red)
                        }
                    }
                }
            }
            .padding(24)
        }
        .navigationTitle(session.displayName)
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
                SessionStatusBadge(session: session, tier: freshnessTier)
            }

            // A row with no figures to show (a scan row's are its runtime)
            // keeps its time on the line above, not on a line of its own.
            let showsFigures = !session.hasProcessHeuristicMetrics || session.error_count > 0

            // A scan row's title already names its provider and project
            // ("Codex · cli-pulse-ios"), so its line keeps only the
            // confidence; no row shows a producer's placeholder project.
            HStack(spacing: 14) {
                if !session.titleNamesProviderAndProject {
                    Label(session.provider, systemImage: "cpu")
                    if let project = session.displayProject {
                        Label(project, systemImage: "folder")
                    }
                }
                if let conf = session.collection_confidence {
                    ConfidenceBadge(confidence: conf)
                }
                if !showsFigures {
                    Spacer(minLength: 8)
                    lastActive
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)

            if showsFigures {
                HStack(spacing: 18) {
                    // Same gate as macOS: process-scan rows (`local-` and
                    // `proc-`) have heuristic metrics that mislead at long
                    // uptimes. Hide the trio for those rows; the badge tells
                    // the story.
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
                    lastActive
                }
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

    private var lastActive: some View {
        Text(RelativeTime.format(session.last_active_at))
            .font(.caption2)
            .foregroundStyle(.tertiary)
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

}
