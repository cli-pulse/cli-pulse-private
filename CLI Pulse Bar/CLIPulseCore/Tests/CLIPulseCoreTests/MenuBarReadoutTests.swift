// The macOS menu bar item's VoiceOver label, and the widget labels built from
// the same `L10n.a11y` clauses.
//
// Asserted in ja / zh-Hans on purpose: English is the fallback copy, so an
// English assertion still passes when the lookup is broken.
import XCTest
@testable import CLIPulseCore

final class MenuBarReadoutTests: XCTestCase {
    /// The app name as `L10n` shows it: "CLI Pulse" joined by a no-break space
    /// (`L10n.keepingBrandUnbroken`). VoiceOver reads it the same either way.
    private let appName = "CLI\u{00A0}Pulse"
    private var savedLocaleOverride: String?
    private let now = Date(timeIntervalSince1970: 1_750_000_000)

    override func setUp() {
        super.setUp()
        savedLocaleOverride = LocaleOverrideStore.shared.override
        LocaleOverrideStore.shared.set("ja")
    }

    override func tearDown() {
        LocaleOverrideStore.shared.set(savedLocaleOverride)
        super.tearDown()
    }

    private func usage(_ provider: String, quota: Int?, remaining: Int?, resetIn: TimeInterval? = nil) -> ProviderUsage {
        ProviderUsage(
            provider: provider,
            today_usage: 0, week_usage: 0,
            estimated_cost_today: 0, estimated_cost_week: 0,
            cost_status_today: "ok", cost_status_week: "ok",
            quota: quota, remaining: remaining,
            reset_time: resetIn.map { ISO8601DateFormatter().string(from: now.addingTimeInterval($0)) },
            status_text: "",
            trend: [], recent_sessions: [], recent_errors: [])
    }

    private func readout(
        signedIn: Bool = true, alerts: Int = 0, mode: MenuBarDisplayMode, top: ProviderUsage?
    ) -> MenuBarReadout {
        MenuBarReadout.resolve(isSignedIn: signedIn, unresolvedAlertCount: alerts, mode: mode,
                               mostUsedProvider: top, now: now)
    }

    // MARK: - Spoken label says what the number is

    /// The reported case: "CLI Pulse, 3", where only a warning-triangle icon
    /// (never announced) said the 3 counts unresolved alerts.
    func test_unresolvedAlerts_areNamed() {
        let r = readout(alerts: 3, mode: .percent, top: usage("Claude", quota: 100, remaining: 28))
        XCTAssertEqual(r, .unresolvedAlerts(3))
        XCTAssertEqual(r.visibleText, "3")
        XCTAssertEqual(r.accessibilityLabel(serverOnline: true), "\(appName)、未解決のアラート 3 件")
    }

    func test_percentMode_saysTheShareIsWhatRemains() {
        let r = readout(mode: .percent, top: usage("Claude", quota: 100, remaining: 28))
        XCTAssertEqual(r.visibleText, "28%")
        XCTAssertEqual(r.accessibilityLabel(serverOnline: true), "\(appName)、Claude、残り 28%")
    }

    /// "▲12%" / "≈" used to be read as "black up-pointing triangle 12 percent"
    /// and "almost equal to". The glyph stays on screen; the words are spoken.
    func test_paceMode_speaksTheVerdictNotTheGlyph() {
        // 5h window, 2h to reset: 60% of the window has elapsed, 40% is used.
        let r = readout(mode: .pace, top: usage("Codex", quota: 100, remaining: 60, resetIn: 2 * 3600))
        XCTAssertEqual(r.visibleText, "▼20%")
        let spoken = r.accessibilityLabel(serverOnline: true)
        XCTAssertEqual(spoken, "\(appName)、Codex、ペース: 20% 余裕")
        XCTAssertFalse(spoken.contains("▼"))
    }

    /// Without a pace verdict the bar shows the USED share — the opposite of
    /// percent mode — so the label has to say which one it is.
    func test_paceModeFallback_saysTheShareIsUsed() {
        let r = readout(mode: .pace, top: usage("Cursor", quota: 100, remaining: 55))
        XCTAssertEqual(r.visibleText, "45%")
        XCTAssertEqual(r.accessibilityLabel(serverOnline: true), "\(appName)、Cursor、45% 使用済み")
    }

    func test_mostUsedMode_namesTheProvider() {
        let r = readout(mode: .mostUsed, top: usage("Gemini", quota: nil, remaining: nil))
        XCTAssertEqual(r.visibleText, "Gemini")
        XCTAssertEqual(r.accessibilityLabel(serverOnline: true), "\(appName)、Gemini")
    }

    /// Offline is shown only as a `wifi.slash` icon, which a listener never hears.
    func test_offlineIsSpoken_whenSignedIn() {
        XCTAssertEqual(readout(mode: .icon, top: nil).accessibilityLabel(serverOnline: false),
                       "\(appName)、オフライン")
        XCTAssertEqual(readout(alerts: 1, mode: .icon, top: nil).accessibilityLabel(serverOnline: false),
                       "\(appName)、未解決のアラート 1 件、オフライン")
    }

    func test_signedOut_isTheAppNameOnly() {
        let r = readout(signedIn: false, alerts: 3, mode: .percent, top: usage("Claude", quota: 100, remaining: 28))
        XCTAssertEqual(r, .signedOut)
        XCTAssertEqual(r.visibleText, "")
        XCTAssertEqual(r.accessibilityLabel(serverOnline: false), appName)
    }

    func test_clausesUseTheLocaleSeparator_inChinese() {
        LocaleOverrideStore.shared.set("zh-Hans")
        let r = readout(alerts: 2, mode: .icon, top: nil)
        XCTAssertEqual(r.accessibilityLabel(serverOnline: false), "\(appName)，2 条未解决告警，离线")
    }

    // MARK: - The visible text is unchanged by the refactor

    /// The readout replaced inline formatting in `AppState.menuBarLabel`; the
    /// menu bar must show exactly what it showed before, at every percentage.
    func test_visibleText_matchesThePreviousFormatting() {
        for remaining in 0...200 {
            let top = usage("Cursor", quota: 200, remaining: remaining)
            let used = top.usagePercent
            let expectedPercentMode = used > 0 ? "\(Int((1.0 - used) * 100))%" : ""
            let expectedPaceMode = used > 0 ? String(format: "%.0f%%", used * 100) : ""
            XCTAssertEqual(readout(mode: .percent, top: top).visibleText, expectedPercentMode, "remaining \(remaining)")
            XCTAssertEqual(readout(mode: .pace, top: top).visibleText, expectedPaceMode, "remaining \(remaining)")
        }
    }

    // MARK: - Widget clauses (L10n.a11y)

    func test_widgetClauses_sayUsedOrRemaining_inChinese() {
        LocaleOverrideStore.shared.set("zh-Hans")
        XCTAssertEqual(L10n.a11y.percentUsed("Claude", 45), "Claude，已使用 45%")
        XCTAssertEqual(L10n.a11y.percentRemaining(L10n.quotaTier.weekly, 60), "每周，剩余 60%")
        XCTAssertEqual(L10n.a11y.percentUsed(nil, 0), "已使用 0%")
    }

    /// With no provider in the snapshot the Lock Screen gauge and the small
    /// overview ring still draw 0; they must say there is no data, not "0% used".
    func test_gaugeWithNoProvider_saysNoData_notZeroUsed() {
        LocaleOverrideStore.shared.set("zh-Hans")
        XCTAssertEqual(L10n.a11y.percentUsedOrNoData(nil, 0), "暂无数据")
        XCTAssertEqual(L10n.a11y.percentUsedOrNoData("Claude", 45), "Claude，已使用 45%")
        XCTAssertEqual(L10n.a11y.usageAndSessions(nil, percentUsed: 0, activeSessions: 0),
                       "暂无数据，0 个活跃会话")
    }

    /// The Lock Screen inline widget shows "Claude 45% • 3 sessions"; what it
    /// says must name the share as used and count sessions with a plural form.
    func test_inlineWidgetLabel_saysUsedAndCountsSessions() {
        LocaleOverrideStore.shared.set("zh-Hans")
        XCTAssertEqual(L10n.a11y.usageAndSessions("Claude", percentUsed: 45, activeSessions: 3),
                       "Claude，已使用 45%，3 个活跃会话")
        // Spanish is where the singular differs ("1 sesiones" would be wrong).
        LocaleOverrideStore.shared.set("es")
        XCTAssertEqual(L10n.a11y.usageAndSessions("Claude", percentUsed: 45, activeSessions: 1),
                       "Claude, 45% usado, 1 sesión activa")
        XCTAssertEqual(L10n.a11y.usageAndSessions("Claude", percentUsed: 45, activeSessions: 2),
                       "Claude, 45% usado, 2 sesiones activas")
    }

    /// The overview widget shows today's totals as bare abbreviations ("1.2M",
    /// "$1.25"); only the large widget puts a title over them, so the small and
    /// medium widgets (and the large one's per-provider cost) say it instead.
    func test_widgetTotals_sayWhatTheNumberIs() {
        XCTAssertEqual(L10n.a11y.usageToday("1.2M"), "今日の使用量、1.2M")
        XCTAssertEqual(L10n.a11y.costToday("$1.25"), "今日のコスト、$1.25")
        LocaleOverrideStore.shared.set("zh-Hans")
        XCTAssertEqual(L10n.a11y.costToday("$1.25"), "今日费用，$1.25")
    }

    /// The single-provider widget draws "120K" and, only when the provider has
    /// a quota, "used" after it. The spoken form follows the screen.
    func test_providerWidgetTokenCount_isNamed_andSaysUsedOnlyWithAQuota() {
        XCTAssertEqual(L10n.a11y.tokenUsage("120K", showsUsed: true), "使用量、120K、使用済み")
        XCTAssertEqual(L10n.a11y.tokenUsage("120K", showsUsed: false), "使用量、120K")
    }

    /// Both fan sliders were read as "adjustable, 40%": no name, and a position
    /// in the range instead of the RPM printed beside them.
    func test_fanTargetSliders_haveANameAndSpeakRPM() {
        XCTAssertEqual(L10n.machine.fanTarget, "目標回転数")
        XCTAssertEqual(L10n.a11y.fanRPM(2400), "2400 RPM")
        // In Auto the iPhone slider follows the live fan, and the screen says so.
        XCTAssertEqual(L10n.a11y.fanRPM(1800, auto: true), "自動、1800 RPM")
    }

    // MARK: - Names of controls whose titles are hidden (`.labelsHidden()`)

    /// Pins only the translation of `machine.sort_by`, the one key the picker
    /// change added (the process sort picker has no visible title of its own).
    /// It is not coverage of the pickers themselves: it passes with every
    /// Picker change reverted. What fails when a picker goes back to
    /// `Picker("", …)` is `UnnamedControlsSweepTests`.
    func test_machineSortByTranslation_resolvesInJapanese() {
        XCTAssertEqual(L10n.machine.sortBy, "並べ替え")
    }

    /// Icon-only buttons whose symbol has no word on screen. Without a label
    /// VoiceOver names them after the SF Symbol, in the system language.
    func test_iconOnlyButtonNames_resolveInJapanese() {
        XCTAssertEqual(L10n.common.clearSearch, "検索テキストを消去")
        XCTAssertEqual(L10n.common.moreOptions, "その他のオプション")
    }
}
