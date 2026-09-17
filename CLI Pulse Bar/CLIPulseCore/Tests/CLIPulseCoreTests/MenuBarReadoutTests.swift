// The macOS menu bar item's VoiceOver label, and the widget labels built from
// the same `L10n.a11y` clauses.
//
// Asserted in ja / zh-Hans on purpose: English is the fallback copy, so an
// English assertion still passes when the lookup is broken.
import XCTest
@testable import CLIPulseCore

final class MenuBarReadoutTests: XCTestCase {
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
        XCTAssertEqual(r.accessibilityLabel(serverOnline: true), "CLI Pulse、未解決のアラート 3 件")
    }

    func test_percentMode_saysTheShareIsWhatRemains() {
        let r = readout(mode: .percent, top: usage("Claude", quota: 100, remaining: 28))
        XCTAssertEqual(r.visibleText, "28%")
        XCTAssertEqual(r.accessibilityLabel(serverOnline: true), "CLI Pulse、Claude、残り 28%")
    }

    /// "▲12%" / "≈" used to be read as "black up-pointing triangle 12 percent"
    /// and "almost equal to". The glyph stays on screen; the words are spoken.
    func test_paceMode_speaksTheVerdictNotTheGlyph() {
        // 5h window, 2h to reset: 60% of the window has elapsed, 40% is used.
        let r = readout(mode: .pace, top: usage("Codex", quota: 100, remaining: 60, resetIn: 2 * 3600))
        XCTAssertEqual(r.visibleText, "▼20%")
        let spoken = r.accessibilityLabel(serverOnline: true)
        XCTAssertEqual(spoken, "CLI Pulse、Codex、ペース: 20% 余裕")
        XCTAssertFalse(spoken.contains("▼"))
    }

    /// Without a pace verdict the bar shows the USED share — the opposite of
    /// percent mode — so the label has to say which one it is.
    func test_paceModeFallback_saysTheShareIsUsed() {
        let r = readout(mode: .pace, top: usage("Cursor", quota: 100, remaining: 55))
        XCTAssertEqual(r.visibleText, "45%")
        XCTAssertEqual(r.accessibilityLabel(serverOnline: true), "CLI Pulse、Cursor、45% 使用済み")
    }

    func test_mostUsedMode_namesTheProvider() {
        let r = readout(mode: .mostUsed, top: usage("Gemini", quota: nil, remaining: nil))
        XCTAssertEqual(r.visibleText, "Gemini")
        XCTAssertEqual(r.accessibilityLabel(serverOnline: true), "CLI Pulse、Gemini")
    }

    /// Offline is shown only as a `wifi.slash` icon, which a listener never hears.
    func test_offlineIsSpoken_whenSignedIn() {
        XCTAssertEqual(readout(mode: .icon, top: nil).accessibilityLabel(serverOnline: false),
                       "CLI Pulse、オフライン")
        XCTAssertEqual(readout(alerts: 1, mode: .icon, top: nil).accessibilityLabel(serverOnline: false),
                       "CLI Pulse、未解決のアラート 1 件、オフライン")
    }

    func test_signedOut_isTheAppNameOnly() {
        let r = readout(signedIn: false, alerts: 3, mode: .percent, top: usage("Claude", quota: 100, remaining: 28))
        XCTAssertEqual(r, .signedOut)
        XCTAssertEqual(r.visibleText, "")
        XCTAssertEqual(r.accessibilityLabel(serverOnline: false), "CLI Pulse")
    }

    func test_clausesUseTheLocaleSeparator_inChinese() {
        LocaleOverrideStore.shared.set("zh-Hans")
        let r = readout(alerts: 2, mode: .icon, top: nil)
        XCTAssertEqual(r.accessibilityLabel(serverOnline: false), "CLI Pulse，2 条未解决告警，离线")
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
}
