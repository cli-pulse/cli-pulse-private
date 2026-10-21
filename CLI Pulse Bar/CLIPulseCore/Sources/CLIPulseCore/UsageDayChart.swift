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
        // The tallest day with a known value. In Cost, a day with usage and
        // no known cost (`Day.costIsUnknown`) has an empty bar, the same as a
        // day with no usage; v1.58 draws an outlined grey stub over its slot
        // (`UnknownCostStub`, in the overlay below).
        let top = days.map { $0.value(metric) }.max() ?? 0
        let stubs = days.filter(metric.drawsUnknownCostStub).map(\.dateKey)
        VStack(alignment: .leading, spacing: 3) {
            Chart(days) { day in
                BarMark(
                    x: .value(L10n.usageDashboard.chartDay, day.dateKey),
                    y: .value(metric.label, day.value(metric)))
                    .foregroundStyle(barColor(day).gradient)
                    .cornerRadius(1.5)
            }
            .chartXAxis(.hidden)
            // Every day unknown: the stubs stand on an axis of 1 that has no
            // figures, so no cost is read off them. Otherwise the axis is
            // Swift Charts' own, as before.
            .modifier(UnknownCostAxis(noKnownValue: top <= 0))
            .chartYAxis {
                AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { value in
                    AxisGridLine()
                    if top > 0, let number = value.as(Double.self) {
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
                    let plot = plotFrame(proxy, geo)
                    ZStack(alignment: .topLeading) {
                        selectionLayer(plot: plot)
                        UnknownCostStubLayer(
                            keys: stubs, columns: days.count, proxy: proxy, plot: plot,
                            selection: selection)
                    }
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

/// v1.58: how the cost charts draw a day with usage and no known cost
/// (`UsageChartMetric.drawsUnknownCostStub`): a short bar on the baseline,
/// outlined and not filled, in a neutral grey, never the provider's colour or
/// the green of a cost. Outlined so that shape, not only colour, tells it from
/// a small filled bar of cost or a dimmed one beside a selected day; grey at
/// systemGray, at least 3:1 on the light card and on the dark panel. The
/// provider panel's chart, the iPhone card's, the Mac card's small one and
/// the Usage Dashboard's Trends all draw it so.
public enum UnknownCostStub {
    /// The outline's grey; the primary colour while its day is the selected
    /// one, as a selected bar keeps its full colour.
    public static func color(selected: Bool = false) -> Color {
        selected ? Color.primary.opacity(0.8) : Color.gray
    }

    /// The outline's width, in points.
    public static let lineWidth: CGFloat = 1.25

    /// Its height, in points, on a chart whose plot is `plotHeight` tall: a
    /// twentieth of it, and never under 6 points, so the outline keeps a
    /// hollow middle; never over 8, so it is not read as a cost.
    public static func height(plotHeight: CGFloat) -> CGFloat {
        min(8, max(6, (plotHeight * 0.05).rounded()))
    }

    /// Its height on the Mac card's small chart (28 points): 4 points, an
    /// outline round a hollow 1.5.
    public static let sparklineHeight: CGFloat = 4

    /// The share of its day's column it is wide: the width Swift Charts
    /// gives the bars beside it (measured on the renders, 0.72 of a column).
    public static let columnShare: CGFloat = 0.72

    /// Where a stub is drawn in a plot of `columns` equal columns, for the
    /// day whose column is centred on `centerX`: on the baseline, as wide as
    /// a bar.
    public static func rect(centerX: CGFloat, columns: Int, plot: CGRect) -> CGRect {
        let column = plot.width / CGFloat(max(columns, 1))
        let width = max(2, column * columnShare)
        let height = Self.height(plotHeight: plot.height)
        return CGRect(x: centerX - width / 2, y: plot.maxY - height, width: width, height: height)
    }

    /// The stub itself.
    public static func shape(selected: Bool = false) -> some View {
        RoundedRectangle(cornerRadius: 1.5)
            .strokeBorder(color(selected: selected), lineWidth: selected ? lineWidth + 0.25 : lineWidth)
    }
}

/// v1.58: the stubs of a Swift Charts bar chart (`UnknownCostStub`), drawn
/// over its plot in the chart's overlay, one on each day in `keys`. Over the
/// plot rather than as marks: a mark can be filled, not outlined. Each is
/// read as its date and "cost unknown" where the chart lets VoiceOver into
/// its parts (Trends); the provider charts read the selected day's line.
@available(iOS 16.0, macOS 13.0, *)
struct UnknownCostStubLayer: View {
    let keys: [String]
    let columns: Int
    let proxy: ChartProxy
    let plot: CGRect
    var selection: String? = nil

    var body: some View {
        ForEach(keys, id: \.self) { key in
            if let x = proxy.position(forX: key) {
                let rect = UnknownCostStub.rect(centerX: plot.minX + x, columns: columns, plot: plot)
                UnknownCostStub.shape(selected: key == selection)
                    .frame(width: rect.width, height: rect.height)
                    .position(x: rect.midX, y: rect.midY)
                    .allowsHitTesting(false)
                    .accessibilityElement()
                    .accessibilityLabel(DisplayFormat.day(key, style: .monthDay) ?? key)
                    .accessibilityValue(L10n.providerPanel.costUnknown)
            }
        }
    }
}

/// v1.58: the y axis of a cost chart none of whose days has a known cost:
/// 0 to 1 and, at its call sites, without figures, so the empty plot the
/// unknown-cost stubs stand on reads no cost. Charts with a known value keep
/// their automatic axis.
@available(iOS 16.0, macOS 13.0, *)
struct UnknownCostAxis: ViewModifier {
    let noKnownValue: Bool

    func body(content: Content) -> some View {
        if noKnownValue {
            content.chartYScale(domain: 0.0...1.0)
        } else {
            content
        }
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
            // v1.58: what a grey bar is, while the chart draws one.
            if days.drawsUnknownCostStub(metric) {
                Text(L10n.providerPanel.costUnknownHelp)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
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
                Text(Self.dayLine(day: day, basis: days.basis, showsCost: showCost))
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

    /// The day detail's line, "Oct 8: ≥$22.99 · 2.5M I/O tokens", with
    /// "I/O" kept on one line when it wraps. VoiceOver reads the chart's own
    /// value (`Day.summary`), which needs no joiner.
    static func dayLine(day: ProviderUsageDays.Day, basis: ProviderUsageDays.TokenBasis, showsCost: Bool) -> String {
        keepingSlashAbbreviationsUnbroken(day.summary(basis: basis, showsCost: showsCost))
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
