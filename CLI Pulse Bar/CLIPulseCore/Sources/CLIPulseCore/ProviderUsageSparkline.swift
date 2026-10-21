#if !os(watchOS)
import SwiftUI

/// v1.57: the small daily chart on a Mac provider card. One bar per day for
/// the last 30 days (`ProviderCardUsage.chartDays`, the panel's own days),
/// measuring what the usage panel was last set to (`UsageChartMetric`).
///
/// Small on purpose: it sits beside the card's Today, This Week and 30 Days
/// figures instead of under them, so the card grows by nothing. Clicking it
/// opens the panel, where a day is read in detail. Tokens are drawn in the provider's colour
/// and cost in the green every cost figure uses, so the colour says which one
/// the bars are. A day with nothing is a gap on the baseline, not a bar. In
/// Cost, a day that has usage and no known cost (`Day.costIsUnknown`) is a
/// short, outlined grey stub instead (v1.58, `UnknownCostStub`), so it does
/// not read as a day with nothing; the chart's help says what the grey bars
/// are.
///
/// Plain shapes rather than Swift Charts: thirty rectangles need no axis, and
/// this draws the same on macOS 13 as on the newest system.
@available(iOS 16.0, macOS 13.0, *)
public struct ProviderUsageSparkline: View {
    public let days: [ProviderUsageDays.Day]
    public let metric: UsageChartMetric
    public let accent: Color

    public init(days: [ProviderUsageDays.Day], metric: UsageChartMetric, accent: Color) {
        self.days = days
        self.metric = metric
        self.accent = accent
    }

    private var barColor: Color {
        metric == .cost ? .green : accent
    }

    public var body: some View {
        let values = days.map { $0.value(metric) }
        let highest = values.max() ?? 0
        GeometryReader { geometry in
            let count = max(values.count, 1)
            let gap: CGFloat = count > 1 ? 1 : 0
            let width = max((geometry.size.width - gap * CGFloat(count - 1)) / CGFloat(count), 1)
            HStack(alignment: .bottom, spacing: gap) {
                ForEach(Array(days.enumerated()), id: \.offset) { index, day in
                    if metric.drawsUnknownCostStub(day) {
                        // Outlined, not filled: a stub, not a small cost.
                        RoundedRectangle(cornerRadius: min(1, width / 2))
                            .strokeBorder(UnknownCostStub.color(), lineWidth: 1)
                            .frame(width: width, height: Self.stubHeight(available: geometry.size.height))
                    } else {
                        RoundedRectangle(cornerRadius: min(1.5, width / 2))
                            .fill(barColor.opacity(0.85))
                            .frame(width: width, height: Self.barHeight(
                                values[index], highest: highest, available: geometry.size.height))
                    }
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .bottomLeading)
        }
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.secondary.opacity(0.25))
                .frame(height: 0.5)
        }
    }

    /// v1.58: the stub's height: `UnknownCostStub.sparklineHeight`, 4
    /// points of the card's 28, so its outline keeps a hollow middle; less
    /// only on a chart shorter than that.
    static func stubHeight(available: CGFloat) -> CGFloat {
        min(UnknownCostStub.sparklineHeight, max(available, 0))
    }

    /// A day with anything at all gets at least a sliver, so a quiet day next
    /// to a busy one still reads as used.
    static func barHeight(_ value: Double, highest: Double, available: CGFloat) -> CGFloat {
        guard value > 0, highest > 0 else { return 0 }
        return max(CGFloat(value / highest) * available, 1.5)
    }
}
#endif
