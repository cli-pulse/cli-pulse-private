import SwiftUI

/// v1.10 P2-1 slice 3: shared renderer for the Overview "Top Projects"
/// card body on the iPhone, from the account's `top_projects`. There is no
/// empty state: the card draws only with rows
/// (`DashboardSummary.showsTopProjectsCard`). Since 1.58 the Mac draws its
/// own card from this Mac's scan (`TopProjectsCard`), so only the iOS style
/// is left.
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

    public init(projects: [TopProject], style: Style) {
        self.projects = projects
        self.style = style
    }

    public var body: some View {
        ForEach(projects) { project in
            HStack {
                Text(project.name)
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
