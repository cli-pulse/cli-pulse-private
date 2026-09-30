import SwiftUI

/// v1.10 P2-1 slice 3: shared renderer for the Overview "Top Projects"
/// card body. Each platform wraps this in its own header + background;
/// the rows and divider logic live here. There is no empty state: the card
/// draws only with rows (`DashboardSummary.showsTopProjectsCard`).
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

        /// Tight menubar typography: 11/10, monospaced digits in rows.
        public static let macOS = Style(
            nameFont: .system(size: 11, weight: .medium),
            amountFont: .system(size: 10, weight: .medium, design: .monospaced),
            rowSpacing: 2
        )

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
