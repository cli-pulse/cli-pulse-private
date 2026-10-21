#if os(macOS)
import SwiftUI

/// v1.58 (P1-4): the lines of a project list (`ProjectUsageList`), as the
/// usage panel's provider mode and the Mac Overview's Top Projects card draw
/// them: "name · cost · tokens", the folder's full path on hover. What each
/// line says, Hide personal information included, is decided in
/// `ProjectUsageList.build`; this only lays it out.
///
/// A grid, as the panel's model rows (`UsageDayModelRows`): the costs end on
/// one edge and the tokens on another, whatever their widths. The tokens are
/// bare figures, as the model rows' are; the card around the list says what
/// they count, and VoiceOver reads each line with its unit.
public struct ProjectUsageListView: View {

    public struct Style: Sendable {
        public var nameFont: Font
        public var figureFont: Font
        public var rowSpacing: CGFloat
        public var showsDividers: Bool
        /// The cost's colour: green on the popover's cards, as every cost
        /// there is; the text colour in the panel, as its model rows are. A
        /// line with no rate draws "No rate" in secondary either way, as a
        /// model row does: it is not a figure.
        public var costColor: Color

        public init(nameFont: Font, figureFont: Font, rowSpacing: CGFloat, showsDividers: Bool, costColor: Color) {
            self.nameFont = nameFont
            self.figureFont = figureFont
            self.rowSpacing = rowSpacing
            self.showsDividers = showsDividers
            self.costColor = costColor
        }

        /// The popover's cards: 11 / 10 points, rows divided, as Top
        /// Projects always drew.
        public static let card = Style(
            nameFont: .system(size: 11, weight: .medium),
            figureFont: .system(size: 10, weight: .medium).monospacedDigit(),
            rowSpacing: 2,
            showsDividers: true,
            costColor: .green)

        /// The slide-out panel: the size of its model rows.
        public static let panel = Style(
            nameFont: .system(size: 11.5, weight: .medium),
            figureFont: .system(size: 11).monospacedDigit(),
            rowSpacing: 3,
            showsDividers: false,
            costColor: .primary)
    }

    private let list: ProjectUsageList
    private let style: Style

    public init(list: ProjectUsageList, style: Style) {
        self.list = list
        self.style = style
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 0) {
                ForEach(list.lines) { line in
                    row(line)
                    if style.showsDividers, line.id != list.lines.last?.id {
                        Divider()
                    }
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
        GridRow {
            Text(line.title)
                .font(style.nameFont)
                .foregroundStyle(line.isUnknown ? .secondary : .primary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
                .help(line.hoverText ?? "")
                // One VoiceOver element per line, read with its unit.
                .accessibilityLabel(line.accessibilityText)
            if let cost = line.costText {
                Text(cost)
                    .font(style.figureFont)
                    .foregroundStyle(line.hasNoRate ? Color.secondary : style.costColor)
                    .lineLimit(1)
                    .fixedSize()
                    .gridColumnAlignment(.trailing)
                    .help(line.costHelp)
                    .accessibilityHidden(true)
            }
            Text(line.tokensFigure)
                .font(style.figureFont)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .fixedSize()
                .gridColumnAlignment(.trailing)
                .accessibilityHidden(true)
        }
        .padding(.vertical, style.rowSpacing)
    }
}

/// "This Mac · Last 30 days" with the laptop the usage panel's scope switch
/// uses: where a project list's figures come from, drawn the same on the
/// Overview card and in the panel.
struct ProjectScopeLabel: View {
    let days: Int
    let size: CGFloat

    var body: some View {
        Label(ProjectUsageList.scopeText(days: days), systemImage: "laptopcomputer")
            .font(.system(size: size))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .fixedSize()
            .help(L10n.providerPanel.scopeThisMacHelp)
    }
}

/// v1.58 (P1-4): the Mac Overview's Top Projects card: this Mac's top
/// projects over the last 30 days, Codex and Claude together, in input +
/// output tokens like the Cost Summary above it
/// (`ProjectUsageList.overview`). Its footnote says what the tokens count,
/// that the costs are estimates (when it shows some), how hidden names are
/// numbered, and which provider's projects it cannot list.
public struct TopProjectsCard: View {
    private let list: ProjectUsageList
    private let folderNote: String?

    /// - Parameter folderNote: `ProjectUsageList.overviewFolderNote`, when
    ///   the App Store build may not read a provider's log folder.
    public init(list: ProjectUsageList, folderNote: String? = nil) {
        self.list = list
        self.folderNote = folderNote
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                SectionHeader(title: L10n.dashboard.topProjects, icon: "folder")
                    .help(L10n.projects.help)
                ProjectScopeLabel(days: ProjectUsageRanking.windowDays, size: 9)
            }
            ProjectUsageListView(list: list, style: .card)
            VStack(alignment: .leading, spacing: 2) {
                Text(ProjectUsageList.overviewFootnote(showsCost: list.showsCost))
                    .help(L10n.cost.ioTokensHelp)
                if list.namesHidden {
                    Text(L10n.projects.numberedHelp)
                }
                if let folderNote {
                    ProjectFolderNote(text: folderNote, size: 9)
                }
            }
            .font(.system(size: 9))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .glassCard(cornerRadius: 8, elevated: false)
    }
}

/// v1.58 (P1-4): the usage panel's Projects card for one provider: its top
/// projects on this Mac, or, when the App Store build may not read the
/// provider's log folder, a note in their place with the way to Settings.
public struct ProviderProjectsCard: View {
    private let list: ProjectUsageList
    private let days: Int
    private let folderNote: String?
    private let onOpenSettings: (() -> Void)?

    /// Whether there is anything to draw: a project, or the note saying why
    /// there is none.
    public static func draws(list: ProjectUsageList, folderNote: String?) -> Bool {
        !list.isEmpty || folderNote != nil
    }

    public init(list: ProjectUsageList, days: Int, folderNote: String?, onOpenSettings: (() -> Void)? = nil) {
        self.list = list
        self.days = days
        self.folderNote = folderNote
        self.onOpenSettings = onOpenSettings
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // A section label, as the totals card's title above it: the
            // panel's heading is the provider's, not this card's.
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(L10n.projects.title)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 8)
                ProjectScopeLabel(days: days, size: 10)
            }
            if list.isEmpty, let folderNote {
                ProjectFolderNote(text: folderNote, size: 10.5)
                if let onOpenSettings {
                    Button(L10n.providers.openSettings, action: onOpenSettings)
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
            } else {
                ProjectUsageListView(list: list, style: .panel)
                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.projects.help)
                    if list.namesHidden {
                        Text(L10n.projects.numberedHelp)
                    }
                }
                .font(.system(size: 9.5))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .glassCard(elevated: false)
    }
}

/// Why a provider's projects are missing, with the icon the panel's empty
/// state asks for folder access with.
struct ProjectFolderNote: View {
    let text: String
    let size: CGFloat

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Image(systemName: "folder.badge.questionmark")
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            Text(text)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.system(size: size))
    }
}
#endif
