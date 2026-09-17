import XCTest
@testable import CLIPulseCore

/// One quota window, one pair of numbers, wherever it is read.
///
/// The quota alert rounded the used percentage ("92% used (8% remaining)")
/// while the iPhone and Mac provider cards and the Watch truncated the left
/// one ("7% left"), so a window 92.1% used said 8% left in one place and 7% in
/// the next.
final class QuotaPercentTests: XCTestCase {

    override func tearDown() {
        LocaleOverrideStore.shared.set(nil)
        super.tearDown()
    }

    // MARK: - The rule

    func test_usedIsRounded_andLeftIsWhatRemainsOfIt() {
        XCTAssertEqual(QuotaPercent.usedAndLeft(quota: 1_000, remaining: 79), QuotaPercent(used: 92, left: 8))
        XCTAssertEqual(QuotaPercent.usedAndLeft(quota: 1_000, remaining: 75), QuotaPercent(used: 93, left: 7), "a half rounds up")
        XCTAssertEqual(QuotaPercent.usedAndLeft(quota: 3, remaining: 1), QuotaPercent(used: 67, left: 33))
        XCTAssertEqual(QuotaPercent.usedAndLeft(usedFraction: 0.921), QuotaPercent(used: 92, left: 8))
    }

    func test_usedAndLeftAddUpToAHundred_onEveryWindowWithinItsQuota() {
        for quota in [1, 3, 7, 100, 999, 1_000, 200_000] {
            for remaining in stride(from: 0, through: quota, by: max(1, quota / 997)) {
                let percent = QuotaPercent.usedAndLeft(quota: quota, remaining: remaining)!
                XCTAssertEqual(percent.used + percent.left, 100, "\(remaining)/\(quota)")
            }
        }
    }

    func test_edges() {
        XCTAssertNil(QuotaPercent.usedAndLeft(quota: 0, remaining: 0))
        XCTAssertNil(QuotaPercent.usedAndLeft(quota: -5, remaining: 0))
        XCTAssertEqual(QuotaPercent.usedAndLeft(quota: 100, remaining: 140), QuotaPercent(used: 0, left: 100))
        // Over quota keeps its overage in used, as the alert always printed.
        XCTAssertEqual(QuotaPercent.usedAndLeft(quota: 100, remaining: -20), QuotaPercent(used: 120, left: 0))
        XCTAssertEqual(QuotaPercent.usedAndLeft(quota: 1, remaining: Int.min), QuotaPercent(used: Int(Int32.max), left: 0),
                       "a count Int cannot subtract must not trap")
        XCTAssertEqual(QuotaPercent.usedAndLeft(usedFraction: .nan), QuotaPercent(used: 0, left: 100))
    }

    /// The alert must print what it printed before this type existed, or every
    /// stored alert row would be rewritten on the next refresh.
    func test_theAlertKeepsTheNumbersItAlwaysStored() {
        for quota in 1...600 {
            for remaining in -quota / 2...quota + 10 {
                let before = Int(round(100.0 * Double(quota - remaining) / Double(quota)))
                guard before > 0 else { continue }    // no threshold is at or below 0
                let now = QuotaPercent.usedAndLeft(quota: quota, remaining: remaining)!
                if now.used != before || now.left != max(0, 100 - before) {
                    return XCTFail("\(remaining)/\(quota): was \(before), now \(now)")
                }
            }
        }
    }

    // MARK: - The surfaces agree

    /// Read in Chinese: the Watch's tier row sits in the same app as the
    /// Alerts page that renders the stored alert, and before this the row said
    /// 剩余 7% under an alert saying 剩余 8%.
    func test_theWatchTierRow_showsTheAlertsRemainingPercent() throws {
        LocaleOverrideStore.shared.set("zh-Hans")
        let provider = ProviderUsage(
            provider: "Codex", today_usage: 0, week_usage: 0,
            estimated_cost_today: 0, estimated_cost_week: 0,
            cost_status_today: "normal", cost_status_week: "normal",
            quota: nil, remaining: nil,
            tiers: [TierDTO(name: "Weekly", quota: 1_000, remaining: 79)],
            status_text: "Operational",
            trend: [], recent_sessions: [], recent_errors: [])
        let dict = try XCTUnwrap(AlertGenerator.evaluateQuotaAlerts(providers: [provider], thresholds: [80]).first)
        let alert = try XCTUnwrap(AlertGenerator.makeAlertRecord(from: dict))
        XCTAssertEqual(alert.message, "Quota window 'Weekly' is 92% used (8% remaining).", "the stored English changed")

        let shown = AlertPresentation.text(for: alert).message
        let row = L10n.watch.percentLeft(WatchRingMath.remainingPercentInt(quota: 1_000, remaining: 79))
        XCTAssertTrue(row.hasPrefix("剩余"), "control: not the English text: \(row)")
        XCTAssertTrue(shown.contains(row), "tier row \(row) is not the alert's \(shown)")
    }

    /// The iPhone and Mac provider tabs live in app targets `swift test` does
    /// not build, so their tier rows are checked in the source: both must take
    /// the percentage from `QuotaPercent` rather than work it out again.
    func test_theIPhoneAndMacTierRows_useTheSharedRule() throws {
        let apps = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()    // …/Tests/CLIPulseCoreTests
            .deletingLastPathComponent()    // …/Tests
            .deletingLastPathComponent()    // …/CLIPulseCore
            .deletingLastPathComponent()    // …/CLI Pulse Bar
        for path in ["CLI Pulse Bar iOS/iOSProvidersTab.swift", "CLI Pulse Bar/ProvidersTab.swift"] {
            let source = try String(contentsOf: apps.appending(path: path), encoding: .utf8)
            let start = try XCTUnwrap(source.range(of: "private func tierDetail(_ tier: UsageTier)"), path)
            let body = String(source[start.upperBound...].prefix(600))
            XCTAssertTrue(body.contains("QuotaPercent.usedAndLeft(quota: quota, remaining: remaining)"), "\(path): \(body)")
            XCTAssertTrue(body.contains("L10n.watch.percentLeft(percent.left)"), "\(path): \(body)")
        }
    }

    /// The rule only holds if nothing works a window's percentage out again.
    /// After the tier rows moved to `QuotaPercent`, the Mac menu bar still
    /// showed "7%" for a window the alert called 8% remaining, Siri said 7%,
    /// the lock-screen and home-screen widgets truncated used (92 beside an
    /// alert at 93), and the medium widget's rows and the Mac's most-constrained
    /// account rounded left on their own (43 where the tier row said 42).
    ///
    /// Most of those surfaces are in app and extension targets `swift test` does
    /// not build, so this reads their source: a quota fraction or count scaled
    /// by 100 by hand is the pattern every one of them used.
    func test_noScreenWorksOutAQuotaPercentageOnItsOwn() throws {
        let apps = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()    // …/Tests/CLIPulseCoreTests
            .deletingLastPathComponent()    // …/Tests
            .deletingLastPathComponent()    // …/CLIPulseCore
            .deletingLastPathComponent()    // …/CLI Pulse Bar
        let scanned = ["CLI Pulse Bar", "CLI Pulse Bar iOS", "CLI Pulse Bar Watch", "CLI Pulse Widgets",
                       "CLIPulseCore/Sources/CLIPulseCore"]
        let handMade = try NSRegularExpression(pattern:
            #"(?i)(usage|used|remaining|left|fraction|percent)\w*\)?\s*\*\s*100\b"# + "|" +
            #"\b100(\.0)?\s*\*\s*\(?\s*(Double\()?\s*(remaining|used|usage|quota)"#)
        // Lines that scale by 100 for something other than showing a window's
        // used or left percentage.
        let notAWindowsPercentage: [(file: String, line: String, why: String)] = [
            ("QuotaPercent.swift", "", "the rule itself"),
            ("ProviderUsage+Pace.swift", "usedPercent: usagePercent * 100", "a Double for the pace engine, never shown"),
            ("DemoDataProvider.swift", "remaining * 100 < quota * lowQuotaPercent", "which demo windows count as low"),
            ("CostCoverage.swift", "Int((fraction * 100).rounded(.down))", "the share of tokens priced, not a quota"),
        ]
        var offenders: [String] = []
        var files = 0
        for directory in scanned {
            let root = apps.appending(path: directory)
            let walker = try XCTUnwrap(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil), directory)
            for case let url as URL in walker {
                // Collectors produce stored status text; their numbers are data, not display.
                if url.pathComponents.contains("Collectors") || url.pathComponents.contains(".build") { continue }
                guard url.pathExtension == "swift" else { continue }
                files += 1
                let source = try String(contentsOf: url, encoding: .utf8)
                for (number, line) in source.components(separatedBy: "\n").enumerated() {
                    let code = line.trimmingCharacters(in: .whitespaces)
                    if code.hasPrefix("//") { continue }
                    guard handMade.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil else { continue }
                    if notAWindowsPercentage.contains(where: { url.lastPathComponent == $0.file && ($0.line.isEmpty || code.contains($0.line)) }) {
                        continue
                    }
                    offenders.append("\(directory)/…/\(url.lastPathComponent):\(number + 1): \(code)")
                }
            }
        }
        XCTAssertGreaterThan(files, 200, "control: the scan found the app sources")
        XCTAssertEqual(offenders, [], "use QuotaPercent.usedAndLeft instead:\n" + offenders.joined(separator: "\n"))
    }
}
