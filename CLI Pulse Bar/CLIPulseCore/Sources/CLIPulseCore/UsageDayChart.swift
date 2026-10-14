#if !os(watchOS)
import Charts
import SwiftUI

// v1.57 (P1-2): the pieces the Mac usage panel's provider mode and the iPhone
// provider card share: daily bars, tokens or cost, one of which can be
// selected, and the selected day's models.

/// One provider's days as bars, one per day, tokens or cost. A day is
/// selected by hovering or clicking on the Mac and by tapping on the iPhone.
///
/// Selection is read from the chart's own plot frame, so a bar is selected
/// wherever the pointer is over its column, however short the bar. macOS 13
/// has no `chartXSelection`, and the iPhone's lets go of the day when the
/// finger lifts, which would close the detail it opens.
@available(iOS 17.0, macOS 13.0, *)
public struct UsageDayBarsChart: View {
    public let days: [ProviderUsageDays.Day]
    public let metric: UsageChartMetric
    public let accent: Color
    @Binding public var selection: String?
    public let height: CGFloat
    /// The Mac panel: the bar under the pointer is selected, and stays
    /// selected when the pointer leaves, so its models can be read.
    public let selectsOnHover: Bool
    /// The iPhone card: tapping the selected bar again clears the selection.
    public let tapTogglesSelection: Bool
    public let axisFontSize: CGFloat
    /// What VoiceOver reads for the selected day: its line as the view below
    /// the chart writes it ("Oct 13: ≈$3.10 · 11.2M tokens"), so moving a
    /// day reads its figures, not only its date.
    public let accessibilityValueText: (ProviderUsageDays.Day) -> String

    public init(
        days: [ProviderUsageDays.Day],
        metric: UsageChartMetric,
        accent: Color,
        selection: Binding<String?>,
        height: CGFloat,
        selectsOnHover: Bool,
        tapTogglesSelection: Bool,
        axisFontSize: CGFloat = 9,
        accessibilityValueText: @escaping (ProviderUsageDays.Day) -> String = { $0.dateText })
    {
        self.days = days
        self.metric = metric
        self.accent = accent
        self._selection = selection
        self.height = height
        self.selectsOnHover = selectsOnHover
        self.tapTogglesSelection = tapTogglesSelection
        self.axisFontSize = axisFontSize
        self.accessibilityValueText = accessibilityValueText
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Chart(days) { day in
                BarMark(
                    x: .value(L10n.usageDashboard.chartDay, day.dateKey),
                    y: .value(metric.label, day.value(metric)))
                    .foregroundStyle(barColor(day).gradient)
                    .cornerRadius(1.5)
            }
            .chartXAxis(.hidden)
            .chartYAxis {
                AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { value in
                    AxisGridLine()
                    if let number = value.as(Double.self) {
                        AxisValueLabel {
                            Text(axisText(number))
                                .font(.system(size: axisFontSize))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .chartOverlay { proxy in
                GeometryReader { geo in
                    selectionLayer(plot: plotFrame(proxy, geo))
                }
            }
            .frame(height: height)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(L10n.providerPanel.chartLabel(metric.label, days.count))
            // VoiceOver moves the selection a day at a time with a swipe up
            // or down; the selected day's models are read below the chart.
            .accessibilityValue(days.first { $0.dateKey == selection }.map(accessibilityValueText) ?? "")
            #if os(iOS)
            .accessibilityHint(L10n.providerPanel.chartHint)
            #endif
            .accessibilityAdjustableAction { direction in
                guard let index = Self.adjustedIndex(
                    from: days.firstIndex { $0.dateKey == selection }, count: days.count,
                    forward: direction == .increment) else { return }
                selection = days[index].dateKey
            }

            // The first and last day under the bars: with 30 bars a label per
            // bar would not fit, and the range is what the reader needs.
            if let first = days.first, let last = days.last {
                HStack {
                    Text(first.dateText)
                    Spacer()
                    Text(last.dateText)
                }
                .font(.system(size: axisFontSize))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            }
        }
    }

    private func barColor(_ day: ProviderUsageDays.Day) -> Color {
        guard let selection, selection != day.dateKey else { return accent }
        return accent.opacity(0.45)
    }

    private func axisText(_ value: Double) -> String {
        metric.axisText(value, top: days.map { $0.value(metric) }.max() ?? 0)
    }

    private func plotFrame(_ proxy: ChartProxy, _ geo: GeometryProxy) -> CGRect {
        #if os(macOS)
        // macOS 13 has only `plotAreaFrame` (`plotFrame` is macOS 14).
        return geo[proxy.plotAreaFrame]
        #else
        return proxy.plotFrame.map { geo[$0] } ?? CGRect(origin: .zero, size: geo.size)
        #endif
    }

    @ViewBuilder
    private func selectionLayer(plot: CGRect) -> some View {
        let layer = Rectangle()
            .fill(Color.clear)
            .contentShape(Rectangle())
            .gesture(SpatialTapGesture().onEnded { value in
                guard let index = Self.dayIndex(atX: value.location.x, plot: plot, count: days.count) else { return }
                let key = days[index].dateKey
                selection = (tapTogglesSelection && selection == key) ? nil : key
            })
        #if os(macOS)
        layer.onContinuousHover { phase in
            guard selectsOnHover, case .active(let point) = phase,
                  let index = Self.dayIndex(atX: point.x, plot: plot, count: days.count) else { return }
            let key = days[index].dateKey
            if selection != key { selection = key }
        }
        #else
        layer
        #endif
    }

    /// The day VoiceOver's adjust moves to from `index` (the newest when
    /// nothing is selected), kept within the `count` days.
    static func adjustedIndex(from index: Int?, count: Int, forward: Bool) -> Int? {
        guard count > 0 else { return nil }
        guard let index else { return count - 1 }
        return min(count - 1, max(0, index + (forward ? 1 : -1)))
    }

    /// The day whose column holds `x`: the plot is `count` equal columns,
    /// one per day, oldest on the left. nil outside the plot.
    static func dayIndex(atX x: CGFloat, plot: CGRect, count: Int) -> Int? {
        guard count > 0, plot.width > 0, x >= plot.minX, x <= plot.maxX else { return nil }
        let column = Int(((x - plot.minX) / plot.width * CGFloat(count)).rounded(.down))
        return min(count - 1, max(0, column))
    }
}

/// The Token / Cost picker.
@available(iOS 17.0, macOS 13.0, *)
public struct UsageMetricPicker: View {
    @Binding public var metric: UsageChartMetric

    public init(metric: Binding<UsageChartMetric>) {
        self._metric = metric
    }

    public var body: some View {
        Picker(L10n.providerPanel.metricPicker, selection: $metric) {
            ForEach(UsageChartMetric.allCases) { Text($0.label).tag($0) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
    }
}

/// A day's models, most expensive first (most tokens first while costs are
/// hidden), each with a short bar in the provider's colour that fades with
/// its rank. A grid, so the cost and token columns line up whatever their
/// widths in each language. The unit is left out of the rows: the day's
/// line above them names it ("tokens", "I/O tokens"), and VoiceOver reads it.
///
/// On the iPhone card at accessibility text sizes each model's figures go on
/// the line under its name instead (`stacksFigures`): in a row the figures
/// keep their full width and the name takes what is left, which on an
/// iPhone 17 Pro was "claude…us-4-1" at AX1 and "…" alone at AX5.
@available(iOS 17.0, macOS 13.0, *)
public struct UsageDayModelRows: View {
    public enum Style: Sendable {
        /// The Mac panel: fixed small sizes, like the rest of the panel.
        case panel
        /// The iPhone card: Dynamic Type.
        case card
    }

    public let rows: [ProviderUsageDays.ModelRow]
    public let basis: ProviderUsageDays.TokenBasis
    public let accent: Color
    public let showsCost: Bool
    public let style: Style

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    public init(
        rows: [ProviderUsageDays.ModelRow],
        basis: ProviderUsageDays.TokenBasis,
        accent: Color,
        showsCost: Bool,
        style: Style)
    {
        self.rows = rows
        self.basis = basis
        self.accent = accent
        self.showsCost = showsCost
        self.style = style
    }

    /// The height of one row in the panel, where the list scrolls inside a
    /// fixed number of rows so the panel does not change height from day to day.
    public static let panelRowHeight: CGFloat = 20

    /// Whether each model's figures go on the line under its name: the
    /// iPhone card at accessibility text sizes, where a row of name, cost and
    /// tokens leaves the name no room. The Mac panel's sizes are fixed.
    static func stacksFigures(style: Style, dynamicTypeSize: DynamicTypeSize) -> Bool {
        style == .card && dynamicTypeSize.isAccessibilitySize
    }

    public var body: some View {
        if Self.stacksFigures(style: style, dynamicTypeSize: dynamicTypeSize) {
            stackedRows
        } else {
            gridRows
        }
    }

    private var orderedRows: [(offset: Int, element: ProviderUsageDays.ModelRow)] {
        Array(ProviderUsageDays.displayOrder(rows, showsCost: showsCost).enumerated())
    }

    private var gridRows: some View {
        Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: style == .panel ? 0 : 6) {
            ForEach(orderedRows, id: \.element.id) { index, row in
                GridRow {
                    RoundedRectangle(cornerRadius: 1)
                        .fill(accent.opacity(Self.rankOpacity(index)))
                        .frame(width: 3, height: style == .panel ? 12 : 14)
                        // The panel's rows keep one height, so its list does
                        // not change height from day to day.
                        .frame(height: style == .panel ? Self.panelRowHeight : nil)
                        .accessibilityHidden(true)
                    // One VoiceOver element per row, read with its unit.
                    Text(row.model)
                        .font(nameFont)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityLabel(accessibilityText(row))
                    if showsCost {
                        costText(row)
                            .gridColumnAlignment(.trailing)
                    }
                    tokensText(row)
                        .gridColumnAlignment(.trailing)
                }
            }
        }
    }

    /// The iPhone card at accessibility sizes: the name on the card's whole
    /// width, wrapping rather than truncating, and its figures under it, side
    /// by side while they fit and one under the other when they do not. The
    /// bar runs down the name and its figures, so each model reads as one.
    private var stackedRows: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(orderedRows, id: \.element.id) { index, row in
                HStack(alignment: .top, spacing: 8) {
                    RoundedRectangle(cornerRadius: 1)
                        .fill(accent.opacity(Self.rankOpacity(index)))
                        .frame(width: 3)
                        .frame(maxHeight: .infinity)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(row.model)
                            .font(nameFont)
                            .fixedSize(horizontal: false, vertical: true)
                        ViewThatFits(in: .horizontal) {
                            HStack(spacing: 8) { figures(row) }
                            VStack(alignment: .leading, spacing: 2) { figures(row) }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .fixedSize(horizontal: false, vertical: true)
                // One VoiceOver element per row, read with its unit.
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(accessibilityText(row))
            }
        }
    }

    @ViewBuilder
    private func figures(_ row: ProviderUsageDays.ModelRow) -> some View {
        if showsCost { costText(row) }
        tokensText(row)
    }

    private func costText(_ row: ProviderUsageDays.ModelRow) -> some View {
        Text(row.costText)
            .font(valueFont)
            .monospacedDigit()
            .foregroundStyle(row.hasNoRate || row.costIsUnknown ? Color.secondary : Color.primary)
            .fixedSize()
            .help(row.costHelp)
            .accessibilityHidden(true)
    }

    private func tokensText(_ row: ProviderUsageDays.ModelRow) -> some View {
        Text(CostFormatter.formatUsage(row.tokens))
            .font(valueFont)
            .monospacedDigit()
            .foregroundStyle(.secondary)
            .fixedSize()
            .accessibilityHidden(true)
    }

    private func accessibilityText(_ row: ProviderUsageDays.ModelRow) -> String {
        ([row.model] + (showsCost ? [row.costText] : []) + [basis.tokensText(row.tokens)])
            .joined(separator: ", ")
    }

    private var nameFont: Font {
        style == .panel ? .system(size: 11) : .caption
    }

    private var valueFont: Font {
        style == .panel ? .system(size: 11) : .caption
    }

    /// 0.9 for the first row, fading by 0.15 a rank to no less than 0.3.
    static func rankOpacity(_ index: Int) -> Double {
        max(0.3, 0.9 - Double(index) * 0.15)
    }
}

/// v1.57 (P1-2): the iPhone provider card's last 30 days as bars, tokens or
/// cost, and the models of a tapped day. Synced rows (`get_daily_usage`,
/// day × model), counted in I/O tokens like the rest of the card; the costs
/// are the estimates each device uploaded.
@available(iOS 17.0, macOS 13.0, *)
public struct ProviderUsageHistorySection: View {
    public let days: ProviderUsageDays
    public let accent: Color
    public let showCost: Bool

    @AppStorage(UsageChartMetric.defaultsKey) private var metricRaw = UsageChartMetric.tokens.rawValue
    /// The tapped day; nil shows no detail. Tapping it again clears it.
    @State private var selection: String?

    public init(days: ProviderUsageDays, accent: Color, showCost: Bool, initialSelection: String? = nil) {
        self.days = days
        self.accent = accent
        self.showCost = showCost
        self._selection = State(initialValue: initialSelection)
    }

    private var metric: UsageChartMetric {
        showCost ? UsageChartMetric.stored(metricRaw) : .tokens
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // The title and the picker share a line while both fit whole.
            // The scope is the section's truth label, so when they do not
            // (accessibility text sizes: Japanese lost "All devices" to "…"
            // at AX1, English at AX5) the picker goes under the title, which
            // wraps.
            ViewThatFits(in: .horizontal) {
                HStack {
                    title.fixedSize()
                    Spacer(minLength: 8)
                    picker
                }
                VStack(alignment: .leading, spacing: 4) {
                    title.fixedSize(horizontal: false, vertical: true)
                    picker
                }
            }
            UsageDayBarsChart(
                days: days.days, metric: metric, accent: accent,
                selection: $selection, height: 90,
                selectsOnHover: false, tapTogglesSelection: true,
                accessibilityValueText: { [basis = days.basis, showsCost = showCost] day in
                    day.summary(basis: basis, showsCost: showsCost)
                })
            if let day = days.day(selection) {
                dayDetail(day)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.15), value: selection)
    }

    /// Whose usage it is: the synced rows are every device's.
    private var title: some View {
        Text(L10n.widget.usageTitle + " · " + days.scope.label)
            .font(.caption2.weight(.medium))
            .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private var picker: some View {
        if showCost {
            UsageMetricPicker(metric: Binding(get: { metric }, set: { metricRaw = $0.rawValue }))
                .controlSize(.mini)
        }
    }

    private func dayDetail(_ day: ProviderUsageDays.Day) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                // Wraps at accessibility sizes; "I/O" stays on one line.
                Text(Self.keepingSlashAbbreviationsUnbroken(day.summary(basis: days.basis, showsCost: showCost)))
                    .font(.caption.weight(.semibold))
                    .monospacedDigit()
                Spacer(minLength: 4)
                Button {
                    selection = nil
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L10n.providerPanel.closeDay)
            }
            UsageDayModelRows(rows: day.models, basis: days.basis, accent: accent,
                              showsCost: showCost, style: .card)
            // The costs are estimates, as everywhere else they are shown, and
            // synced costs can leave out tokens the uploading device had no
            // rate for. The section's only truth labels, so not its faintest
            // text.
            if showCost {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.usageDashboard.costDisclaimer)
                    if days.scope == .allDevices {
                        Text(L10n.providerPanel.scopeAllDevicesHelp)
                    }
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(10)
        .background(Color.primary.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    /// `text` with a word joiner (U+2060) after each slash that stands
    /// between two letters, so "I/O" (Spanish "E/S") is never split over two
    /// lines: a slash is a line-break opportunity, and when the day's line
    /// wraps at accessibility text sizes it read "2.5M I/" over "O tokens".
    /// The joiner is invisible and VoiceOver passes over it.
    static func keepingSlashAbbreviationsUnbroken(_ text: String) -> String {
        guard text.contains("/") else { return text }
        let characters = Array(text)
        var result = ""
        for (index, character) in characters.enumerated() {
            result.append(character)
            if character == "/", index > 0, index + 1 < characters.count,
               characters[index - 1].isLetter, characters[index + 1].isLetter {
                result.append("\u{2060}")
            }
        }
        return result
    }
}
#endif
