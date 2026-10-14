// UsagePanel — v1.57 (P1-2). What the panel that slides out of the popover
// shows, in its two modes:
//
// - all providers: the Usage Dashboard, from this Mac's usage archive;
// - one provider: its last 30 days by day and model, from this Mac's scan
//   (or the rows synced to the account), with a Token / Cost toggle.
//
// `UsagePanelModel` keeps the data live. The panel used to be handed the
// archive snapshot it opened with and never read it again (D11), so a panel
// left open across a refresh kept showing the old figures.

#if os(macOS)
import AppKit
import Combine
import SwiftUI

@MainActor
public final class UsagePanelModel: ObservableObject {
    public enum Mode: Equatable, Sendable {
        case allProviders
        case provider(String)
    }

    @Published public var mode: Mode
    /// This Mac's usage archive, read again every time it is written.
    @Published public private(set) var archive: DailyUsageArchive?
    /// This Mac's scan rows, as the last refresh left them.
    @Published public private(set) var scanEntries: [CostUsageScanResult.DailyEntry] = [] {
        didSet { daysCache = [:] }
    }
    /// The rows synced to the account (`AppState.dailyUsage`); none while
    /// signed out.
    @Published public private(set) var cloudRows: [DailyUsage] = [] {
        didSet { daysCache = [:] }
    }
    /// The days built from the rows above, by day, scope and provider: the
    /// panel asks for them several times a redraw. Emptied whenever the rows
    /// change; keyed by today, so a panel left open past midnight moves on.
    private var daysCache: [String: ProviderUsageDays] = [:]
    /// Whether the scan came back empty because macOS blocks the log folders.
    @Published public private(set) var needsFolderAccess = false
    /// The scope picked for a provider that has both.
    @Published public var scopeChoice: [String: UsageDataScope] = [:]

    private let loadArchive: @Sendable () async -> DailyUsageArchive
    private let now: () -> Date
    private var archiveObservers: Set<AnyCancellable> = []
    private var sourceObservers: Set<AnyCancellable> = []
    private var reloadTask: Task<Void, Never>?
    /// Bumped by every reload, so an older read that finishes last cannot
    /// replace a newer one. A seed's caller reads it before its own read
    /// (`seed(archive:readStartedAt:)`).
    private(set) var reloadGeneration = 0
    /// The generation the shown archive was read at: a reload started after
    /// it is newer.
    private var shownGeneration = -1

    public init(
        mode: Mode = .allProviders,
        notificationCenter: NotificationCenter = .default,
        now: @escaping () -> Date = Date.init,
        loadArchive: @escaping @Sendable () async -> DailyUsageArchive = UsagePanelModel.thisMacsArchive)
    {
        self.mode = mode
        self.now = now
        self.loadArchive = loadArchive
        // Posted from the archive's actor, off the main thread.
        notificationCenter.publisher(for: .dailyUsageArchiveDidChange)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.reloadArchive() }
            .store(in: &archiveObservers)
    }

    /// This Mac's archive, as the panel reads it outside tests.
    @Sendable public nonisolated static func thisMacsArchive() async -> DailyUsageArchive {
        await DailyUsageArchiveManager.shared.snapshot()
    }

    /// The archive the panel opens with, read before it is shown so it is
    /// sized to the loaded dashboard rather than to a spinner. `startedAt` is
    /// `reloadGeneration` as it was before that read began.
    ///
    /// A reload started before the read (the archive is written while the
    /// panel is hidden too) is no newer than it, and is discarded. One
    /// started during the read, because the archive was written meanwhile,
    /// is newer: it is left to finish and replace this, and when it already
    /// has, this is dropped.
    public func seed(archive: DailyUsageArchive, readStartedAt startedAt: Int) {
        if startedAt == reloadGeneration {
            reloadGeneration += 1
            reloadTask?.cancel()
            reloadTask = nil
            show(archive, readAt: reloadGeneration)
        } else if shownGeneration <= startedAt {
            // What is shown is older than this read (an earlier opening's):
            // this stands in until the newer reload lands.
            show(archive, readAt: startedAt)
        }
    }

    /// Reads the archive again. Runs on every `dailyUsageArchiveDidChange`.
    public func reloadArchive() {
        reloadGeneration += 1
        let generation = reloadGeneration
        reloadTask = Task { [weak self, loadArchive] in
            let fresh = await loadArchive()
            guard let self, generation == self.reloadGeneration else { return }
            self.show(fresh, readAt: generation)
        }
    }

    private func show(_ archive: DailyUsageArchive, readAt generation: Int) {
        self.archive = archive
        shownGeneration = generation
    }

    /// Waits for the last reload to finish (tests).
    func settle() async {
        await reloadTask?.value
    }

    /// The reload started last, so a test can wait for an older one after a
    /// newer one has started.
    var currentReloadTask: Task<Void, Never>? { reloadTask }

    /// Follows a refresh's scan, the synced rows and the folder-access flag.
    public func follow(
        scan: AnyPublisher<CostUsageScanResult?, Never>,
        cloud: AnyPublisher<[DailyUsage], Never>,
        needsFolderAccess: AnyPublisher<Bool, Never>)
    {
        sourceObservers = []
        scan.map { $0?.entries ?? [] }
            .sink { [weak self] in self?.scanEntries = $0 }
            .store(in: &sourceObservers)
        cloud
            .sink { [weak self] in self?.cloudRows = $0 }
            .store(in: &sourceObservers)
        needsFolderAccess
            .sink { [weak self] in self?.needsFolderAccess = $0 }
            .store(in: &sourceObservers)
    }

    public func follow(_ state: AppState) {
        follow(
            scan: state.$costUsageScanResult.eraseToAnyPublisher(),
            cloud: state.$dailyUsage.eraseToAnyPublisher(),
            needsFolderAccess: state.$needsScannerFolderAccess.eraseToAnyPublisher())
    }

    // MARK: Provider mode

    private var todayKey: String { DayKey.string(from: now()) }

    /// `provider`'s days in `scope`.
    public func days(for provider: String, in scope: UsageDataScope) -> ProviderUsageDays {
        let today = todayKey
        let key = "\(today)|\(scope.rawValue)|\(provider)"
        if let built = daysCache[key] { return built }
        let built = Self.days(provider: provider, scope: scope, scan: scanEntries, cloud: cloudRows, todayKey: today)
        daysCache[key] = built
        return built
    }

    /// The scopes with usage for `provider` in the window, This Mac first.
    public func availableScopes(for provider: String) -> [UsageDataScope] {
        UsageDataScope.allCases.filter { days(for: provider, in: $0).hasUsage }
    }

    /// v1.57: shows `provider` on `scope` from now on, as picking it in the
    /// panel does. A provider card opening the panel passes the scope its own
    /// figures are labelled with, so the panel starts where the card is. Like
    /// a pick, it holds only while that scope has usage (`scope(for:)`).
    public func prefer(_ scope: UsageDataScope, for provider: String) {
        scopeChoice[provider] = scope
    }

    /// The scope shown for `provider`: the one picked, while it has usage,
    /// else This Mac when it has usage, else All devices when it has, else
    /// This Mac (whose empty state says why).
    public func scope(for provider: String) -> UsageDataScope {
        let available = availableScopes(for: provider)
        if let chosen = scopeChoice[provider], available.contains(chosen) { return chosen }
        return available.first ?? .thisMac
    }

    static func days(
        provider: String, scope: UsageDataScope,
        scan: [CostUsageScanResult.DailyEntry], cloud: [DailyUsage], todayKey: String) -> ProviderUsageDays
    {
        switch scope {
        case .thisMac: return .fromScan(scan, provider: provider, todayKey: todayKey)
        case .allDevices: return .fromCloud(cloud, provider: provider, todayKey: todayKey)
        }
    }

    /// Whether the panel has a provider mode worth opening for `provider`:
    /// usage in the last 30 days on this Mac or in the synced rows. What the
    /// provider card asks before it shows its button.
    public static func hasHistory(
        provider: String, scan: CostUsageScanResult?, cloud: [DailyUsage], now: Date = Date()) -> Bool
    {
        ProviderUsageDays.hasUsage(
            provider: provider, scan: scan?.entries ?? [], cloud: cloud, todayKey: DayKey.string(from: now))
    }
}

// MARK: - Provider mode

/// One provider's last 30 days: bars, the selected day's models, the total.
/// Laid out at a height that does not change from day to day, so the panel
/// does not jump as the pointer moves over the bars.
public struct ProviderUsagePanelView: View {
    public let data: ProviderUsageDays
    public let availableScopes: [UsageDataScope]
    @Binding public var scope: UsageDataScope
    public let needsFolderAccess: Bool
    /// Back to the Usage Dashboard; nil hides the button.
    public let onShowAllProviders: (() -> Void)?
    /// Opens the popover's Settings, where the log folders are granted; nil
    /// hides the button.
    public let onOpenSettings: (() -> Void)?

    @AppStorage(UsageChartMetric.defaultsKey) private var metricRaw = UsageChartMetric.tokens.rawValue
    @AppStorage("cli_pulse_show_cost") private var showCost = true
    @ObservedObject private var localeOverride = LocaleOverrideStore.shared
    @Environment(\.colorScheme) private var colorScheme
    /// nil: the latest day with usage.
    @State private var selection: String?

    /// Model rows visible at once; more scroll.
    static let visibleModelRows = 5
    static let windowDays = 30

    public init(
        data: ProviderUsageDays,
        availableScopes: [UsageDataScope],
        scope: Binding<UsageDataScope>,
        needsFolderAccess: Bool,
        onShowAllProviders: (() -> Void)?,
        onOpenSettings: (() -> Void)? = nil,
        initialSelection: String? = nil)
    {
        self.data = data
        self.availableScopes = availableScopes
        self._scope = scope
        self.needsFolderAccess = needsFolderAccess
        self.onShowAllProviders = onShowAllProviders
        self.onOpenSettings = onOpenSettings
        self._selection = State(initialValue: initialSelection)
    }

    private var accent: Color { PulseTheme.providerColor(data.provider) }

    private var metric: UsageChartMetric {
        showCost ? UsageChartMetric.stored(metricRaw) : .tokens
    }

    private var metricBinding: Binding<UsageChartMetric> {
        Binding(get: { metric }, set: { metricRaw = $0.rawValue })
    }

    private var selectionBinding: Binding<String?> {
        Binding(get: { selection ?? data.latestActiveDayKey }, set: { selection = $0 })
    }

    private var selectedDay: ProviderUsageDays.Day? {
        data.day(selection ?? data.latestActiveDayKey)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            if data.hasUsage {
                chartCard
                totalsCard
            } else {
                emptyState
            }
        }
        .languageKeyed(localeOverride.override)
        .padding(.horizontal, 26)
        .padding(.vertical, 22)
        .frame(maxWidth: .infinity, alignment: .leading)
        // The same frosted backdrop as the Usage Dashboard's.
        .background(HUDWindowBackground(isDark: colorScheme == .dark).ignoresSafeArea())
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let onShowAllProviders {
                Button(action: onShowAllProviders) {
                    Label(L10n.providerPanel.allProviders, systemImage: "chevron.left")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            // The scope beside the title when both fit on one row, else on a
            // row of its own under it: "Este Mac | Todos los dispositivos"
            // does not fit beside the Spanish title at any width the panel
            // takes, and the title must not wrap into a narrow column.
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center, spacing: 10) {
                    providerIcon
                    titles
                    Spacer(minLength: 8)
                    scopeControl
                }
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .center, spacing: 10) {
                        providerIcon
                        titles
                        Spacer(minLength: 0)
                    }
                    scopeControl
                }
            }
        }
        // Clear of the close button the panel lays over its top-right corner.
        .padding(.trailing, 18)
    }

    private var providerIcon: some View {
        Image(systemName: ProviderKind(rawValue: data.provider)?.iconName ?? "chart.bar.xaxis")
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(accent)
            .frame(width: 30, height: 30)
            .background(accent.opacity(0.15))
            .clipShape(RoundedRectangle(cornerRadius: 7))
    }

    private var titles: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(data.provider)
                .font(.system(size: 15, weight: .semibold))
                .lineLimit(1)
            Text(L10n.providerPanel.title + " · " + L10n.providerPanel.lastDays(Self.windowDays))
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    @ViewBuilder
    private var scopeControl: some View {
        if availableScopes.count > 1 {
            Picker(L10n.providerPanel.scopePicker, selection: $scope) {
                ForEach(availableScopes) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .controlSize(.small)
            .help(scopeHelp)
        } else {
            // Where the figures come from; not a control, so not drawn as one.
            Label(scope.label, systemImage: scope == .thisMac ? "laptopcomputer" : "icloud")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .fixedSize()
                .help(scopeHelp)
        }
    }

    private var scopeHelp: String {
        scope == .thisMac ? L10n.providerPanel.scopeThisMacHelp : L10n.providerPanel.scopeAllDevicesHelp
    }

    // MARK: Chart and day

    private var chartCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            if showCost {
                HStack {
                    Spacer()
                    UsageMetricPicker(metric: metricBinding)
                        .controlSize(.small)
                }
            }
            UsageDayBarsChart(
                days: data.days, metric: metric, accent: accent,
                selection: selectionBinding, height: 130,
                selectsOnHover: true, tapTogglesSelection: false,
                accessibilityValueText: { [basis = data.basis, showsCost = showCost] day in
                    day.summary(basis: basis, showsCost: showsCost)
                })
            Divider().opacity(0.5)
            dayDetail
        }
        .padding(14)
        .glassCard(elevated: false)
    }

    /// The most rows any day of the window lists, up to `visibleModelRows`:
    /// the list keeps this height whichever day is selected.
    private var modelViewportRows: Int {
        min(Self.visibleModelRows, max(1, data.days.map(\.models.count).max() ?? 1))
    }

    @ViewBuilder
    private var dayDetail: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let day = selectedDay {
                Text(day.summary(basis: data.basis, showsCost: showCost))
                    .font(.system(size: 12, weight: .semibold))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .help(showCost ? day.costHelp : "")
                let height = CGFloat(modelViewportRows) * UsageDayModelRows.panelRowHeight
                let rows = UsageDayModelRows(
                    rows: day.models, basis: data.basis, accent: accent,
                    showsCost: showCost, style: .panel)
                Group {
                    if day.models.count > Self.visibleModelRows {
                        ScrollView { rows }
                    } else {
                        rows
                    }
                }
                .frame(height: height, alignment: .top)
            }
        }
    }

    // MARK: Totals

    private var totalsCard: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(showCost ? L10n.providerPanel.estTotal(Self.windowDays) : L10n.providerPanel.total(Self.windowDays))
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
            Text(showCost
                 ? L10n.providerPanel.totalValue(data.totalCostText, CostFormatter.formatUsage(data.totalTokens))
                 : L10n.providerPanel.modelTokens(CostFormatter.formatUsage(data.totalTokens)))
                .font(.system(size: 17, weight: .semibold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .help(showCost ? data.totalCostHelp : "")
            if showCost, let top = data.topModelByCost {
                Text(L10n.providerPanel.topModel(top))
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            if showCost, data.coverage.shouldDisclose, let percent = data.coverage.pricedPercent {
                Text(L10n.cost.coverageSummary(percent, data.coverage.unpricedModels.count))
                    .font(.system(size: 10))
                    .foregroundStyle(.orange)
                    .help(L10n.cost.coverageHelp(CostCoverage.tooltipList(data.coverage.unpricedModels)))
            }
            if showCost, data.coverage.hasApproximatePrices {
                Text(L10n.cost.approximateSummary(data.coverage.approximateModels.count))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .help(L10n.cost.approximateHelp(CostCoverage.tooltipList(data.coverage.approximateModels)))
            }
            // The estimate's own line, as legible as the figures it qualifies.
            if showCost {
                Text(L10n.usageDashboard.costDisclaimer)
                    .font(.system(size: 9.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 3)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(L10n.providerPanel.tokenBasis)
                // The header names the scope; this says what it means.
                Text(scopeHelp)
            }
            .font(.system(size: 9.5))
            .foregroundStyle(.tertiary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, showCost ? 0 : 3)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .glassCard(elevated: false)
    }

    /// Whether the empty panel asks for the log folders: macOS blocks them,
    /// the scope is this Mac's, and `provider` is one the scan reads (Codex,
    /// Claude). For any other, granting access would show nothing more.
    static func asksForFolderAccess(provider: String, scope: UsageDataScope, needsFolderAccess: Bool) -> Bool {
        needsFolderAccess && scope == .thisMac
            && CostUsageScanner.logProviders.contains { $0.rawValue == provider }
    }

    /// Nothing to draw. When macOS blocks this Mac's log folders, whether
    /// there was usage is not known, so it says that, not "no usage".
    private var emptyState: some View {
        VStack(spacing: 6) {
            if Self.asksForFolderAccess(provider: data.provider, scope: scope, needsFolderAccess: needsFolderAccess) {
                Image(systemName: "folder.badge.questionmark")
                    .font(.system(size: 22))
                    .foregroundStyle(.orange)
                Text(L10n.providers.grantAccessTitle)
                    .font(.system(size: 12, weight: .medium))
                    .multilineTextAlignment(.center)
                Text(L10n.providers.grantAccessBody)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                if let onOpenSettings {
                    Button(L10n.providers.openSettings, action: onOpenSettings)
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .padding(.top, 4)
                }
            } else {
                Image(systemName: "chart.bar.xaxis")
                    .font(.system(size: 22))
                    .foregroundStyle(.secondary)
                Text(L10n.providerPanel.empty(Self.windowDays))
                    .font(.system(size: 12, weight: .medium))
            }
        }
        .frame(maxWidth: .infinity, minHeight: 160)
    }
}

// MARK: - The panel's content, in either mode

/// What the slide-out panel hosts. Measures its own natural height and
/// reports it, so the panel follows content that grows or shrinks (a refresh,
/// a mode switch), and scrolls only when taller than the screen allows.
struct UsagePanelRootView: View {
    @ObservedObject var model: UsagePanelModel
    let width: CGFloat
    let maxHeight: CGFloat
    let onHeightChange: (CGFloat) -> Void
    let onClose: () -> Void
    var onOpenSettings: (() -> Void)? = nil
    @State private var naturalHeight: CGFloat = 0

    var body: some View {
        let fits = naturalHeight <= maxHeight
        ScrollView(.vertical) {
            UsagePanelContent(model: model, onOpenSettings: onOpenSettings)
                .frame(width: width)
                .background(GeometryReader { geo in
                    Color.clear.preference(key: UsagePanelHeightKey.self, value: geo.size.height)
                })
        }
        .scrollDisabled(fits)
        .scrollIndicators(fits ? .hidden : .automatic)
        .frame(width: width)
        .onPreferenceChange(UsagePanelHeightKey.self) { height in
            naturalHeight = height
            onHeightChange(min(height, maxHeight))
        }
        .overlay(alignment: .topTrailing) {
            Button(action: onClose) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 17))
                    .foregroundStyle(.secondary)
                    .padding(8)
            }
            .buttonStyle(.plain)
            .help(L10n.common.close)
            .accessibilityLabel(L10n.common.close)
        }
        .background(HUDWindowBackground(isDark: true).ignoresSafeArea())
        // token-monitor look: the slide-out panel is always dark frosted
        // glass, regardless of the system theme. The hosting view applies
        // `displayLocaleRoot()` (`DisplayLocaleRootTests` reads it there).
        .environment(\.colorScheme, .dark)
    }
}

/// The panel's content in its current mode, at its natural height.
struct UsagePanelContent: View {
    @ObservedObject var model: UsagePanelModel
    var onOpenSettings: (() -> Void)? = nil

    var body: some View {
        switch model.mode {
        case .allProviders:
            if let archive = model.archive {
                UsageDashboardView(
                    archive: archive, scrollable: false, showsCodexHistoryLine: true,
                    onSelectProvider: { provider in model.mode = .provider(provider) })
            } else {
                ProgressView().frame(maxWidth: .infinity, minHeight: 400)
            }
        case .provider(let provider):
            let scope = model.scope(for: provider)
            ProviderUsagePanelView(
                data: model.days(for: provider, in: scope),
                availableScopes: model.availableScopes(for: provider),
                scope: Binding(
                    get: { model.scope(for: provider) },
                    set: { model.scopeChoice[provider] = $0 }),
                needsFolderAccess: model.needsFolderAccess,
                onShowAllProviders: { model.mode = .allProviders },
                onOpenSettings: onOpenSettings)
                // A new provider starts on its own latest day.
                .id(provider)
        }
    }
}

private struct UsagePanelHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}
#endif
