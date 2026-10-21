#if os(macOS)
import SwiftUI

/// v1.58 (P1-4): the lines of a project list (`ProjectUsageList`), as the
/// usage panel's provider mode and the Mac Overview's Top Projects card draw
/// them: "name · cost · tokens", the folder's full path on hover. What each
/// line says, Hide personal information included, is decided in
/// `ProjectUsageList.build`; this only lays it out.
public struct ProjectUsageListView: View {

    public struct Style: Sendable {
        public var nameFont: Font
        public var figureFont: Font
        public var rowSpacing: CGFloat
        public var showsDividers: Bool

        public init(nameFont: Font, figureFont: Font, rowSpacing: CGFloat, showsDividers: Bool) {
            self.nameFont = nameFont
            self.figureFont = figureFont
            self.rowSpacing = rowSpacing
            self.showsDividers = showsDividers
        }

        /// The popover's cards: 11 / 10 points, rows divided, as Top
        /// Projects always drew.
        public static let card = Style(
            nameFont: .system(size: 11, weight: .medium),
            figureFont: .system(size: 10, weight: .medium).monospacedDigit(),
            rowSpacing: 2,
            showsDividers: true)

        /// The slide-out panel: the size of its model rows.
        public static let panel = Style(
            nameFont: .system(size: 11.5, weight: .medium),
            figureFont: .system(size: 11).monospacedDigit(),
            rowSpacing: 3,
            showsDividers: false)
    }

    private let list: ProjectUsageList
    private let style: Style

    public init(list: ProjectUsageList, style: Style) {
        self.list = list
        self.style = style
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(list.lines) { line in
                row(line)
                    .padding(.vertical, style.rowSpacing)
                if style.showsDividers, line.id != list.lines.last?.id {
                    Divider()
                }
            }
            if let more = list.shownOfText {
                Text(more)
                    .font(.system(size: 9.5))
                    .foregroundStyle(.tertiary)
                    .padding(.top, 4)
            }
        }
    }

    private func row(_ line: ProjectUsageLine) -> some View {
        HStack(spacing: 8) {
            Text(line.title)
                .font(style.nameFont)
                .foregroundStyle(line.isUnknown ? .secondary : .primary)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(line.hoverText ?? "")
                .layoutPriority(1)
            Spacer(minLength: 6)
            if let cost = line.costText {
                Text(cost)
                    .font(style.figureFont)
                    .foregroundStyle(.green)
                    .lineLimit(1)
                    .fixedSize()
                    .help(line.costHelp)
            }
            Text(line.tokensText)
                .font(style.figureFont)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .fixedSize()
        }
        .accessibilityElement(children: .combine)
    }
}

/// v1.58 (P1-4): the Mac Overview's Top Projects card: this Mac's top
/// projects over the last 30 days, Codex and Claude together, each token
/// counted once (`ProjectUsageList.build` with `basis: .eachOnce`, as
/// `OverviewTab` builds it). Says where its figures come from and how it
/// counts them, since nothing else on the Overview is per project.
public struct TopProjectsCard: View {
    private let list: ProjectUsageList

    public init(list: ProjectUsageList) {
        self.list = list
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                SectionHeader(title: L10n.dashboard.topProjects, icon: "folder")
                Text(ProjectUsageList.scopeText())
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .fixedSize()
            }
            .help(L10n.projects.help)
            ProjectUsageListView(list: list, style: .card)
            Text(L10n.providerPanel.tokenBasis)
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .glassCard(cornerRadius: 8, elevated: false)
    }
}
#endif
