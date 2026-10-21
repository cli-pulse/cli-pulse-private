#if os(macOS)
import SwiftUI

/// v1.58 (P1-5): the usage panel's Sessions card for one provider: this
/// Mac's sessions over the panel's window, a row each (project, model, I/O
/// and cached tokens, estimated cost, last activity, subagents), most
/// expensive first or latest first. What each row says, Hide personal
/// information included, is decided in `SessionUsageList.build`; this lays it
/// out.
///
/// It shows the first five, as Projects shows its top five, says under them
/// how many of how many it shows, and shows more a page at a time ("Show 20
/// more"). The card has no scroll view of its own: the rows it shows are part
/// of the panel, which scrolls as a whole when it is taller than the screen
/// (on a laptop it is, with this card), so a scroll over the list moves the
/// panel, and no row is ever out of reach behind a scroll view nothing
/// signals or that the panel's own `.scrollDisabled` turned off.
///
/// Built from the scan's rows, which the panel hands over unchanged on every
/// redraw (hovering the chart redraws the panel), so it is `Equatable` and
/// compares those by identity: the list is worked out again only when they,
/// or the switches, change.
public struct ProviderSessionsCard: View, Equatable {
    private let sessions: [CostUsageScanResult.SessionEntry]
    private let details: [CostUsageScanResult.SessionDetail]
    private let projects: [CostUsageScanResult.ProjectEntry]
    private let provider: String
    private let days: Int
    private let todayKey: String
    private let showsCost: Bool
    private let hidePersonalInfo: Bool

    @State private var order: SessionUsageRanking.Order
    /// How many rows are shown: the first page, more after "Show more".
    @State private var shown: Int

    /// - Parameters:
    ///   - projects: this Mac's rows by project, every provider's: with Hide
    ///     personal information on, a session's project keeps the number
    ///     Projects gives it.
    ///   - initialOrder: the order the card opens in; cost, as the plan has
    ///     it, everywhere but a QA render of the other.
    ///   - initialShown: how many rows it opens with; the first page
    ///     everywhere but a QA render of more.
    public init(
        sessions: [CostUsageScanResult.SessionEntry],
        details: [CostUsageScanResult.SessionDetail],
        projects: [CostUsageScanResult.ProjectEntry],
        provider: String,
        days: Int = SessionUsageRanking.windowDays,
        todayKey: String,
        showsCost: Bool,
        hidePersonalInfo: Bool,
        initialOrder: SessionUsageRanking.Order = .cost,
        initialShown: Int = SessionUsageList.firstPage)
    {
        self.sessions = sessions
        self.details = details
        self.projects = projects
        self.provider = provider
        self.days = days
        self.todayKey = todayKey
        self.showsCost = showsCost
        self.hidePersonalInfo = hidePersonalInfo
        self._order = State(initialValue: initialOrder)
        self._shown = State(initialValue: max(SessionUsageList.firstPage, initialShown))
    }

    public static func == (lhs: ProviderSessionsCard, rhs: ProviderSessionsCard) -> Bool {
        lhs.provider == rhs.provider && lhs.days == rhs.days && lhs.todayKey == rhs.todayKey
            && lhs.showsCost == rhs.showsCost && lhs.hidePersonalInfo == rhs.hidePersonalInfo
            && lhs.sessions == rhs.sessions && lhs.details == rhs.details && lhs.projects == rhs.projects
    }

    /// Whether the card has a session to list for `provider` over the
    /// window: the panel draws it only then.
    public static func hasSessions(
        _ sessions: [CostUsageScanResult.SessionEntry], provider: String,
        days: Int = SessionUsageRanking.windowDays, todayKey: String) -> Bool
    {
        let window = ProviderUsageDays.windowCache.window(count: days, endingAt: todayKey, timeZone: .current).set
        return sessions.contains { $0.provider == provider && window.contains($0.date) }
    }

    private var list: SessionUsageList {
        SessionUsageList.build(
            sessions, details: details, projects: projects, provider: provider, days: days,
            todayKey: todayKey, showsCost: showsCost, hidePersonalInfo: hidePersonalInfo, order: order)
    }

    public var body: some View {
        let list = list
        VStack(alignment: .leading, spacing: 8) {
            // A section label, as the Projects card's above it.
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(L10n.sessions.title)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 8)
                ProjectScopeLabel(days: days, size: 10)
            }
            if list.lines.count > 1 {
                HStack {
                    Spacer(minLength: 0)
                    Picker(L10n.sessionHistory.sortPicker, selection: $order) {
                        ForEach(SessionUsageRanking.Order.allCases) { order in
                            Text(order.label(showsCost: showsCost)).tag(order)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                    .controlSize(.small)
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(list.visibleLines(shown)) { line in
                        SessionUsageRowView(line: line)
                    }
                }
                pager(list)
            }
            VStack(alignment: .leading, spacing: 2) {
                ForEach(list.footnote, id: \.self) { line in
                    Text(line)
                }
            }
            .font(.system(size: 9.5))
            .foregroundStyle(.tertiary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .glassCard(elevated: false)
    }

    /// Under the rows, where Projects says "Top 5 of 7 projects": how many
    /// of how many are shown, and the buttons that show more or go back to
    /// the first page.
    private func pager(_ list: SessionUsageList) -> some View {
        let more = list.moreCount(after: shown)
        return HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(list.shownText(shown))
                .font(.system(size: 9.5))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
            Spacer(minLength: 8)
            if more > 0 {
                Button(L10n.sessionHistory.showMore(more)) {
                    shown = list.visibleLines(shown).count + more
                }
                .buttonStyle(.plain)
                .font(.system(size: 10))
                .foregroundStyle(PulseTheme.accent)
                .lineLimit(1)
                .fixedSize()
            }
            if list.canShowLess(shown) {
                Button(L10n.sessionHistory.showLess) {
                    shown = SessionUsageList.firstPage
                }
                .buttonStyle(.plain)
                .font(.system(size: 10))
                .foregroundStyle(PulseTheme.accent)
                .lineLimit(1)
                .fixedSize()
            }
        }
    }
}

/// One session: the project and the cost on the first line, the model and
/// tokens under it, when it was last active and its subagents last.
struct SessionUsageRowView: View {
    let line: SessionUsageLine

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(line.title)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(line.isUnknown ? .secondary : .primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .help(line.hoverText ?? "")
                if let cost = line.costText {
                    Text(cost)
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(line.hasNoRate ? Color.secondary : Color.primary)
                        .lineLimit(1)
                        .fixedSize()
                        .help(line.costHelp)
                }
            }
            Text(line.usageText)
                .font(.system(size: 10).monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(line.usageHelp)
            Text(line.activityText)
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        // One VoiceOver element per session, its shorthand spelled out
        // (`SessionUsageLine.accessibilityText`).
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(line.accessibilityText)
    }
}
#endif
