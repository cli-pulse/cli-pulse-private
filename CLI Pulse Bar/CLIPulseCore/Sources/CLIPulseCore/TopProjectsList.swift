import SwiftUI

/// v1.10 P2-1 slice 3: shared renderer for the Overview "Top Projects"
/// card body on the iPhone, from the account's `top_projects`. There is no
/// empty state: the card draws only with rows
/// (`DashboardSummary.showsTopProjectsCard`). Since 1.58 the Mac draws its
/// own card from this Mac's scan (`TopProjectsCard`), so only the iOS style
/// is left.
///
/// v1.58 (P1-6): with "Hide personal information" on, a project is "Hidden
/// project" (`PersonalInfoMask.projectName`; the iPhone has no scan to number
/// it by). Nothing fills `top_projects` today, so this is for the day
/// something does.
public struct TopProjectsList: View {

    public struct Style: Sendable {
        public var nameFont: Font
        public var amountFont: Font
        public var rowSpacing: CGFloat

        public init(nameFont: Font, amountFont: Font, rowSpacing: CGFloat) {
            self.nameFont = nameFont
            self.amountFont = amountFont
            self.rowSpacing = rowSpacing
        }

        /// iOS uses Dynamic Type sizes with monospaced digits for numbers.
        public static let iOS = Style(
            nameFont: .subheadline.weight(.medium),
            amountFont: .caption.monospacedDigit(),
            rowSpacing: 2
        )
    }

    private let projects: [TopProject]
    private let style: Style
    private let hidePersonalInfo: Bool

    public init(projects: [TopProject], style: Style, hidePersonalInfo: Bool) {
        self.projects = projects
        self.style = style
        self.hidePersonalInfo = hidePersonalInfo
    }

    public var body: some View {
        ForEach(projects) { project in
            HStack {
                Text(PersonalInfoMask.projectName(project.name, numbers: .none, hidePersonalInfo: hidePersonalInfo) ?? "")
                    .font(style.nameFont)
                    .lineLimit(1)
                Spacer()
                Text(CostFormatter.formatUsage(project.usage))
                    .font(style.amountFont)
                    .foregroundStyle(.secondary)
                Text(CostFormatter.format(project.estimated_cost))
                    .font(style.amountFont)
                    .foregroundStyle(.green)
            }
            .padding(.vertical, style.rowSpacing)
            if project.id != projects.last?.id {
                Divider()
            }
        }
    }
}
