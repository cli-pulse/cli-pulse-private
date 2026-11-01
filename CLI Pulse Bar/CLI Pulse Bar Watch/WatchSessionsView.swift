import SwiftUI
import CLIPulseCore

/// Live (sessions) page. Sessions the iPhone's Sessions tab lists under
/// Active are featured as cards (provider colour bar + project +
/// provider·duration); ones it lists under Recent are dimmed compact rows
/// below. Drill-down to the detail view is preserved.
///
/// 1.61 (B4, 59-09): the rows are classified as the iPhone and the Mac
/// classify them (`WatchLivePage`, `SessionFreshnessTierClassifier`) at the
/// Watch's `sessionsClock`, not by each row's stored status: the cloud keeps a
/// row "Running" until its device syncs again, so a Mac asleep with AI tools
/// open left them here. The header's count is the Pulse chip's figure. The
/// decorative activity spark is gone (C6): it drew bars from the session's id,
/// not from any activity.
///
/// A process-scan row (`SessionRecord.hasProcessHeuristicMetrics`, every
/// session in the cloud today) shows no usage, cost or requests, as on the
/// iPhone: its figures are its runtime through a formula, not usage.
///
/// Presentation-only — reads `state.*`, never mutates the data layer.
/// Owns one `ScrollView` (review R1).
struct WatchSessionsView: View {
    @EnvironmentObject var state: WatchAppState

    var body: some View {
        // One clock for the sections and the rows' badges.
        let now = state.sessionsClock()
        let sections = state.liveSections(at: now)
        return ScrollView {
            LazyVStack(spacing: 8) {
                header(liveCount: sections.live.count)

                if !sections.live.isEmpty || !sections.recent.isEmpty {
                    ForEach(sections.live) { session in
                        NavigationLink {
                            WatchSessionDetailView(session: session, showCost: state.showCost,
                                                   deviceNumbers: state.deviceNameNumbers)
                        } label: {
                            SessionCard(session: session, showCost: state.showCost)
                        }
                        .buttonStyle(.plain)
                    }
                    ForEach(sections.recent) { session in
                        NavigationLink {
                            WatchSessionDetailView(session: session, showCost: state.showCost,
                                                   deviceNumbers: state.deviceNameNumbers)
                        } label: {
                            SessionCompactRow(session: session, now: now)
                        }
                        .buttonStyle(.plain)
                    }
                } else if state.lastRefresh == nil && state.isLoading {
                    // Don't show "No sessions" before the first load resolves.
                    WatchLoadingState()
                } else if state.lastRefresh == nil, let err = state.lastError {
                    WatchErrorState(title: L10n.watch.couldntLoadData, message: err) {
                        Task { await state.refreshAll() }
                    }
                } else {
                    emptyState
                }
            }
            .padding(.horizontal, 2)
        }
        .refreshable { await state.refreshAll() }
    }

    private func header(liveCount: Int) -> some View {
        HStack(spacing: 5) {
            LiveDot(size: 7)
            Text(L10n.watch.live)
                .font(.system(size: 13, weight: .semibold))
            Spacer()
            if liveCount > 0 {
                Text(L10n.sessions.countRunning(liveCount))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.bottom, 2)
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "terminal")
                .font(.title3)
                .foregroundStyle(.tertiary)
            Text(L10n.sessions.noSessions)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
    }
}

// MARK: - Running session card (featured)

struct SessionCard: View {
    let session: SessionRecord
    let showCost: Bool
    /// v1.58 (P1-6): "Hide personal information", the iPhone's choice
    /// (`PersonalInfoMask.adoptPhoneChoice`): the title and project are
    /// masked. No project numbers: the Watch has no scan.
    @AppStorage(PersonalInfoMask.defaultsKey) private var hidePersonalInfo = false

    private var color: Color { PulseTheme.providerColor(session.provider) }

    var body: some View {
        HStack(spacing: 9) {
            RoundedRectangle(cornerRadius: 2)
                .fill(color)
                .frame(width: 3)

            VStack(alignment: .leading, spacing: 3) {
                // The project, or the row's title when there is none to show
                // (a producer's placeholder: "Claude process", translated).
                Text(PersonalInfoMask.sessionProject(session, numbers: .none, hidePersonalInfo: hidePersonalInfo)
                    ?? PersonalInfoMask.sessionTitle(session, numbers: .none, hidePersonalInfo: hidePersonalInfo))
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)

                Text("\(session.provider) · \(RelativeTime.format(session.started_at))")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                // The iPhone row's gate: a scan row's figures are runtime.
                if !session.hasProcessHeuristicMetrics {
                    HStack(spacing: 4) {
                        Text(CostFormatter.formatUsage(session.total_usage))
                            .font(WatchTheme.monoNumber(size: 11))
                        if showCost && session.estimated_cost > 0 {
                            Text(CostFormatter.format(session.estimated_cost))
                                .font(.system(size: 9).monospacedDigit())
                                .foregroundStyle(.green)
                        }
                        Spacer(minLength: 0)
                    }
                }
            }
            // The card spans the page whether or not it has a figures line
            // (that line's spacer used to stretch it).
            Spacer(minLength: 0)
        }
        .padding(8)
        .background(WatchTheme.cardFillStrong, in: RoundedRectangle(cornerRadius: WatchTheme.cardRadius))
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Recent session row (dimmed)

struct SessionCompactRow: View {
    let session: SessionRecord
    /// The Live page's clock: the row's badge is its tier there ("Recent"), as
    /// on the iPhone, not its stored status.
    let now: Date
    /// v1.58 (P1-6): "Hide personal information", the iPhone's choice
    /// (`PersonalInfoMask.adoptPhoneChoice`): the title and project are
    /// masked. No project numbers: the Watch has no scan.
    @AppStorage(PersonalInfoMask.defaultsKey) private var hidePersonalInfo = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: session.providerKind?.iconName ?? "terminal")
                .font(.caption2)
                .foregroundStyle(PulseTheme.providerColor(session.provider))
                .frame(width: 16)

            Text(PersonalInfoMask.sessionProject(session, numbers: .none, hidePersonalInfo: hidePersonalInfo)
                ?? PersonalInfoMask.sessionTitle(session, numbers: .none, hidePersonalInfo: hidePersonalInfo))
                .font(.caption)
                .lineLimit(1)

            Spacer(minLength: 4)

            StatusBadge(text: SessionFreshnessTierClassifier.classify(session, now: now).badge, color: .secondary)
                .scaleEffect(0.82)

            // The iPhone row's gate: a scan row's figures are runtime.
            if !session.hasProcessHeuristicMetrics {
                Text(CostFormatter.formatUsage(session.total_usage))
                    .font(WatchTheme.monoNumber(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 8)
        .background(WatchTheme.cardFill, in: RoundedRectangle(cornerRadius: WatchTheme.cardRadius))
        .opacity(0.7)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Session Detail

struct WatchSessionDetailView: View {
    let session: SessionRecord
    let showCost: Bool
    /// 1.60 (C9): the devices the Watch holds, numbered for "Device N".
    var deviceNumbers: DeviceNameNumbers = .none
    /// v1.58 (P1-6): "Hide personal information", the iPhone's choice
    /// (`PersonalInfoMask.adoptPhoneChoice`): the title and project are
    /// masked. No project numbers: the Watch has no scan.
    @AppStorage(PersonalInfoMask.defaultsKey) private var hidePersonalInfo = false

    var body: some View {
        List {
            Section {
                HStack(spacing: 6) {
                    Image(systemName: session.providerKind?.iconName ?? "terminal")
                        .foregroundStyle(PulseTheme.providerColor(session.provider))
                    VStack(alignment: .leading, spacing: 2) {
                        // The iPhone detail's title: a scan row's provider
                        // and project, not its command line.
                        Text(PersonalInfoMask.sessionTitle(
                            session, numbers: .none, hidePersonalInfo: hidePersonalInfo))
                            .font(.caption.weight(.bold))
                            .lineLimit(2)
                        StatusBadge(
                            text: L10n.status.localized(session.status),
                            color: PulseTheme.statusColor(session.status)
                        )
                        .scaleEffect(0.85)
                    }
                }
            }

            Section(L10n.sessions.details) {
                // One session's fields: the singular detail labels the iPhone
                // session detail uses, not the plural dashboard headings
                // ("Top Projects: my-app") or the alert's "Created".
                WatchMetricRow(label: L10n.detail.provider, value: session.provider, icon: "cpu")
                WatchMetricRow(
                    label: L10n.detail.project,
                    value: PersonalInfoMask.sessionDetailProject(
                        session, numbers: .none, hidePersonalInfo: hidePersonalInfo),
                    icon: "folder")
                WatchMetricRow(label: L10n.detail.device, value: PersonalInfoMask.deviceName(
                    session.device_name, numbers: deviceNumbers, hidePersonalInfo: hidePersonalInfo) ?? "",
                    icon: "desktopcomputer")
                WatchMetricRow(label: L10n.detail.started, value: RelativeTime.format(session.started_at), icon: "clock")
            }

            // The figures the iPhone detail shows: none of a scan row's, and
            // the request count only where its row shows one.
            if !session.hasProcessHeuristicMetrics || session.error_count > 0 {
                Section(L10n.dashboard.quickStats) {
                    if !session.hasProcessHeuristicMetrics {
                        WatchMetricRow(
                            label: L10n.widget.usageTitle,
                            value: CostFormatter.formatUsage(session.total_usage),
                            icon: "chart.bar.fill"
                        )
                        if showCost {
                            WatchMetricRow(
                                label: L10n.detail.cost,  // the session's whole cost, not today's
                                value: CostFormatter.format(session.estimated_cost),
                                icon: "dollarsign.circle",
                                valueColor: .green
                            )
                        }
                        if session.hasMeaningfulRequestCount {
                            WatchMetricRow(
                                label: L10n.dashboard.requests,
                                value: "\(session.requests)",
                                icon: "arrow.up.arrow.down"
                            )
                        }
                    }
                    if session.error_count > 0 {
                        WatchMetricRow(
                            label: L10n.watch.errors,
                            value: "\(session.error_count)",
                            icon: "exclamationmark.triangle",
                            valueColor: .red
                        )
                    }
                }
            }
        }
        // Short, as the Quota detail's is: the header already reads
        // "Codex · cli-pulse-ios", which as a Watch title scrolled.
        .navigationTitle(session.provider)
    }
}
