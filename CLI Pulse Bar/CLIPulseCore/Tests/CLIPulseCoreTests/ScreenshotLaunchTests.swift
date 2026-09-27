#if DEBUG
import XCTest
@testable import CLIPulseCore

/// The App Store screenshot capture launch (`ScreenshotLaunch`): how it reads
/// its arguments, what it puts on screen, what it may not reach, and that none
/// of it can end up in a Release build.
final class ScreenshotLaunchTests: XCTestCase {

    private typealias Launch = ScreenshotLaunch

    private func parse(_ args: String...) -> Launch.Parsed {
        Launch.parse(["/path/to/CLI Pulse.app/CLI Pulse"] + args)
    }

    private func request(_ screen: Launch.Screen) -> Launch.Parsed {
        .request(Launch.Request(screen: screen))
    }

    private func assertInvalid(_ parsed: Launch.Parsed, mentioning needle: String,
                               file: StaticString = #filePath, line: UInt = #line) {
        guard case .invalid(let reason) = parsed else {
            return XCTFail("expected .invalid, got \(parsed)", file: file, line: line)
        }
        XCTAssertTrue(reason.contains(needle), "\(reason) does not mention \(needle)",
                      file: file, line: line)
    }

    // MARK: - Parsing

    func test_aNormalLaunchIsNotACapture() {
        XCTAssertEqual(parse(), .notRequested)
        XCTAssertEqual(parse("-AppleLanguages", "(ja)", "-AppleLocale", "ja_JP"), .notRequested)
        XCTAssertEqual(Launch.parse([]), .notRequested)
    }

    func test_everyScreenCanBeRequested_amongOtherArguments() {
        for screen in Launch.Screen.allCases {
            XCTAssertEqual(
                parse("-AppleLanguages", "(zh-Hant)", "-CLIPulseScreenshotDemo", "YES",
                      "-AppleLocale", "zh_TW", "-CLIPulseScreenshotScreen", screen.rawValue),
                request(screen), screen.rawValue)
            // Order of the two flags does not matter.
            XCTAssertEqual(
                parse("-CLIPulseScreenshotScreen", screen.rawValue, "-CLIPulseScreenshotDemo", "YES"),
                request(screen), screen.rawValue)
        }
    }

    func test_theDemoFlagReadsBooleansTheWayUserDefaultsDoes() {
        for yes in ["YES", "yes", "true", "TRUE", "1"] {
            XCTAssertEqual(parse("-CLIPulseScreenshotDemo", yes), request(.overview), yes)
        }
        for no in ["NO", "no", "false", "0"] {
            XCTAssertEqual(parse("-CLIPulseScreenshotDemo", no), .notRequested, no)
        }
    }

    /// A capture that fell back to a normal launch would photograph whatever
    /// the app opened on and file it under the requested name. Every one of
    /// these has to stop the launch instead.
    func test_argumentsThatCannotBeHonouredAreErrors() {
        assertInvalid(parse("-CLIPulseScreenshotDemo"), mentioning: "needs a value")
        assertInvalid(parse("-CLIPulseScreenshotDemo", "YES", "-CLIPulseScreenshotScreen"),
                      mentioning: "needs a value")
        assertInvalid(parse("-CLIPulseScreenshotDemo", "maybe"), mentioning: "'maybe'")
        assertInvalid(parse("-CLIPulseScreenshotDemo", "YES", "-CLIPulseScreenshotScreen", "settings"),
                      mentioning: "overview, providers, cost, sessions, alerts")
        assertInvalid(parse("-CLIPulseScreenshotDemo", "YES", "-CLIPulseScreenshotScreen", "Cost"),
                      mentioning: "'Cost'")
        assertInvalid(parse("-CLIPulseScreenshotScreen", "cost"), mentioning: "needs -CLIPulseScreenshotDemo YES")
        assertInvalid(parse("-CLIPulseScreenshotDemo", "NO", "-CLIPulseScreenshotScreen", "cost"),
                      mentioning: "needs -CLIPulseScreenshotDemo YES")
        assertInvalid(parse("-CLIPulseScreenshotDemo", "YES", "-CLIPulseScreenshotDemo", "YES"),
                      mentioning: "twice")
        assertInvalid(parse("-CLIPulseScreenshotDemo", "YES",
                            "-CLIPulseScreenshotScreen", "cost", "-CLIPulseScreenshotScreen", "alerts"),
                      mentioning: "twice")
    }

    // MARK: - Screens

    func test_eachScreenOpensItsTab_andOnlyCostScrolls() {
        XCTAssertEqual(Launch.Screen.overview.tab, .overview)
        XCTAssertEqual(Launch.Screen.cost.tab, .overview, "cost is the Overview scrolled to Cost Summary")
        XCTAssertEqual(Launch.Screen.providers.tab, .providers)
        XCTAssertEqual(Launch.Screen.sessions.tab, .sessions)
        XCTAssertEqual(Launch.Screen.alerts.tab, .alerts)
        for screen in Launch.Screen.allCases {
            XCTAssertTrue(screen.tab.isVisible, "\(screen) opens a tab the iPhone does not offer")
            XCTAssertEqual(screen.scrollTarget, screen == .cost ? .costSummary : nil, screen.rawValue)
        }
    }

    /// The capture script names the screens (and so the file names 01…05) on
    /// its own. If the two lists drift, a screen is captured under another's
    /// name or not at all.
    func test_theCaptureScriptNamesTheSameScreensInTheSameOrder() throws {
        let script = try String(contentsOf: Self.appSourceRoot
            .appendingPathComponent("scripts/capture_ios_screenshots.sh"), encoding: .utf8)
        let line = try XCTUnwrap(
            script.split(separator: "\n").first { $0.hasPrefix("SCREENS=(") },
            "no SCREENS=( … ) line in capture_ios_screenshots.sh")
        let names = line.dropFirst("SCREENS=(".count).prefix { $0 != ")" }
            .split(separator: " ").map(String.init)
        XCTAssertEqual(names, Launch.Screen.allCases.map(\.rawValue))
        XCTAssertTrue(script.contains(Launch.demoArgument), "the script does not pass \(Launch.demoArgument)")
        XCTAssertTrue(script.contains(Launch.screenArgument), "the script does not pass \(Launch.screenArgument)")
        XCTAssertTrue(script.contains(Launch.readyMarker), "the script does not wait for \(Launch.readyMarker)")
        XCTAssertTrue(script.contains(Launch.errorMarker), "the script does not watch for \(Launch.errorMarker)")
    }

    // MARK: - The capture environment

    private var productionRuntime: CLIPulseRuntimeEnvironment {
        .resolveForTesting(infoDictionary: ["CFBundleIdentifier": "yyh.CLI-Pulse"], environment: [:])
    }

    func test_theCaptureEnvironmentCanReachNothing() {
        let production = productionRuntime
        XCTAssertTrue(production.allowsProductionCloudEndpoints, "positive control: production reaches the cloud")
        XCTAssertTrue(production.capabilities.allowsCloudSessionRestore, "positive control")

        let capture = production.restrictedForScreenshotCapture()
        XCTAssertEqual(capture.bundleIdentifier, production.bundleIdentifier)
        XCTAssertEqual(capture.channel, production.channel)
        XCTAssertFalse(capture.allowsProductionCloudEndpoints)
        let quarantine = CLIPulseRuntimeEnvironment.resolveForTesting(infoDictionary: [:], environment: [:])
        XCTAssertEqual(capture.capabilities, quarantine.capabilities, "every capability off")

        // Mirror-read every flag, so a capability added later that defaults on
        // cannot slip past the comparison above unnoticed.
        for child in Mirror(reflecting: capture.capabilities).children {
            XCTAssertEqual(child.value as? Bool, false, "\(child.label ?? "?") is on in a capture")
        }

        let cloud = RuntimeCloudConfiguration.resolve(
            runtimeEnvironment: capture, explicitURL: nil, explicitAnonKey: nil,
            infoDictionary: ["SUPABASE_URL": RuntimeCloudConfiguration.productionURL,
                             "SUPABASE_ANON_KEY": "real-looking-key"],
            environment: [:])
        XCTAssertEqual(cloud.url, RuntimeCloudConfiguration.localInvalidURL)
        XCTAssertNotEqual(cloud.anonKey, "real-looking-key")
    }

    @MainActor
    func test_applyingARequestEntersDemoOnItsTab() throws {
        let suite = "ScreenshotLaunchTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        for screen in Launch.Screen.allCases {
            let state = AppState(
                runtimeEnvironment: productionRuntime.restrictedForScreenshotCapture(),
                defaults: defaults,
                performLaunchSetup: false)
            XCTAssertFalse(state.isAuthenticated, "positive control")

            Launch.apply(Launch.Request(screen: screen), to: state)

            XCTAssertTrue(state.isDemoMode, screen.rawValue)
            XCTAssertTrue(state.isAuthenticated, screen.rawValue)
            XCTAssertEqual(state.selectedTab, screen.tab, screen.rawValue)
            XCTAssertFalse(state.sessions.isEmpty, "\(screen): no demo sessions")
            XCTAssertFalse(state.alerts.isEmpty, "\(screen): no demo alerts")
            XCTAssertNotNil(state.dashboard, "\(screen): no demo dashboard")
        }
    }

    /// READY is a claim about what is on screen, so it is checked against the
    /// state rather than printed on a timer: a launch that ended up elsewhere
    /// reports ERROR, and the capture script stops instead of photographing it.
    @MainActor
    func test_readyIsPrintedOnlyWhenTheAppIsOnTheRequestedScreen() throws {
        let suite = "ScreenshotLaunchTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        func applied(_ screen: Launch.Screen) -> AppState {
            let state = AppState(
                runtimeEnvironment: productionRuntime.restrictedForScreenshotCapture(),
                defaults: defaults,
                performLaunchSetup: false)
            Launch.apply(Launch.Request(screen: screen), to: state)
            return state
        }

        for screen in Launch.Screen.allCases {
            XCTAssertEqual(Launch.readinessLine(for: Launch.Request(screen: screen), state: applied(screen)),
                           "\(Launch.readyMarker) \(screen.rawValue)")
        }

        let movedAway = applied(.alerts)
        movedAway.selectedTab = .overview
        let line = Launch.readinessLine(for: Launch.Request(screen: .alerts), state: movedAway)
        XCTAssertTrue(line.hasPrefix("\(Launch.errorMarker) alerts:"), line)
        XCTAssertTrue(line.contains("on the Overview tab, not Alerts"), line)

        let leftDemo = applied(.providers)
        leftDemo.isDemoMode = false
        leftDemo.isAuthenticated = false
        let left = Launch.readinessLine(for: Launch.Request(screen: .providers), state: leftDemo)
        XCTAssertTrue(left.hasPrefix(Launch.errorMarker), left)
        XCTAssertTrue(left.contains("not in Demo mode") && left.contains("not signed in"), left)
    }

    /// The Recent tier on the Sessions screen and a named Gemini window on
    /// Providers are part of what the screenshots show; without them the
    /// Sessions panel was half empty and Gemini's bar said "Default".
    func test_demoDataFillsTheScreensItIsPhotographedOn() throws {
        let demo = DemoDataProvider.generate()
        let buckets = SessionFreshnessTierClassifier.partition(demo.sessions, now: Date())
        XCTAssertEqual(buckets.active.count, 3, "the Active section")
        XCTAssertEqual(buckets.recent.map(\.name), ["docs-refresh", "api-gateway"],
                       "the Recent section, most recent first")
        XCTAssertEqual(demo.dashboard.active_sessions, buckets.active.count,
                       "the Sessions tile counts what the Active section lists")

        let gemini = try XCTUnwrap(demo.providers.first { $0.provider == "Gemini" })
        XCTAssertEqual(gemini.tiers.map(\.name), ["Pro"], "the window GeminiCollector reports, by model family")
        XCTAssertFalse(demo.alerts.contains { $0.id.hasPrefix("quota-") && $0.related_provider == "Gemini" },
                       "Gemini at 71% must stay under the 80% warning threshold")
    }

    // MARK: - Compiled out of Release

    /// Every use of the capture launch sits inside `#if DEBUG`, in the package
    /// and in every app target. That is what keeps it out of the Release build
    /// that reaches customers; the release binary check in the PR that added
    /// this is a one-off, this runs on every change.
    func test_everyUseIsInsideIfDebug() throws {
        let roots = ["CLIPulseCore/Sources", "CLI Pulse Bar iOS", "CLI Pulse Bar",
                     "CLI Pulse Bar Watch", "CLI Pulse Widgets", "CLIPulseHelper"]
        let symbols = ["ScreenshotLaunch", "restrictedForScreenshotCapture",
                       Launch.demoArgument, Launch.screenArgument]
        var uses = 0
        var outside: [String] = []
        let fm = FileManager.default
        for root in roots {
            let base = Self.appSourceRoot.appendingPathComponent(root)
            guard let walker = fm.enumerator(at: base, includingPropertiesForKeys: nil) else { continue }
            for case let url as URL in walker where url.pathExtension == "swift" {
                let text = try String(contentsOf: url, encoding: .utf8)
                guard symbols.contains(where: text.contains) else { continue }
                for (line, number) in Self.linesOutsideIfDebug(text, mentioning: symbols) {
                    outside.append("\(root)/\(url.lastPathComponent):\(number): \(line)")
                }
                uses += 1
            }
        }
        // Positive control: the scan found the files that use it.
        XCTAssertGreaterThanOrEqual(uses, 5, "the scan found \(uses) files; is the root wrong?")
        XCTAssertEqual(outside, [], "used outside #if DEBUG, so it would ship in Release")
    }

    /// The scanner itself, against lines that must and must not pass.
    func test_theIfDebugScannerTellsInsideFromOutside() {
        let symbols = ["ScreenshotLaunch"]
        let inside = """
        #if DEBUG
        let a = ScreenshotLaunch.current
        #if os(iOS)
        let b = ScreenshotLaunch.current
        #endif
        #endif
        """
        XCTAssertTrue(Self.linesOutsideIfDebug(inside, mentioning: symbols).isEmpty)

        let bare = "let a = ScreenshotLaunch.current"
        XCTAssertEqual(Self.linesOutsideIfDebug(bare, mentioning: symbols).count, 1)

        let elseBranch = """
        #if DEBUG
        let a = 1
        #else
        let a = ScreenshotLaunch.current
        #endif
        """
        XCTAssertEqual(Self.linesOutsideIfDebug(elseBranch, mentioning: symbols).count, 1)

        let negated = """
        #if !DEBUG
        let a = ScreenshotLaunch.current
        #endif
        """
        XCTAssertEqual(Self.linesOutsideIfDebug(negated, mentioning: symbols).count, 1)

        let otherCondition = """
        #if os(iOS)
        let a = ScreenshotLaunch.current
        #endif
        """
        XCTAssertEqual(Self.linesOutsideIfDebug(otherCondition, mentioning: symbols).count, 1)

        let comment = "// ScreenshotLaunch is documented here"
        XCTAssertTrue(Self.linesOutsideIfDebug(comment, mentioning: symbols).isEmpty,
                      "a comment compiles to nothing")
    }

    /// Code lines that mention a symbol while no enclosing `#if` branch is
    /// exactly `DEBUG`. Whole-line comments are skipped.
    static func linesOutsideIfDebug(_ text: String, mentioning symbols: [String]) -> [(String, Int)] {
        var stack: [Bool] = []   // per open #if: is the active branch `DEBUG`?
        var found: [(String, Int)] = []
        for (offset, raw) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#if ") {
                stack.append(line.dropFirst(4).trimmingCharacters(in: .whitespaces) == "DEBUG")
            } else if line.hasPrefix("#elseif") || line.hasPrefix("#else") {
                if !stack.isEmpty { stack[stack.count - 1] = false }
            } else if line.hasPrefix("#endif") {
                _ = stack.popLast()
            } else if !line.hasPrefix("//"), !line.hasPrefix("///"),
                      symbols.contains(where: line.contains), !stack.contains(true) {
                found.append((line, offset + 1))
            }
        }
        return found
    }

    /// `CLI Pulse Bar/`, which holds the package and every app target.
    private static var appSourceRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // CLIPulseCoreTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // CLIPulseCore
            .deletingLastPathComponent()   // CLI Pulse Bar
    }
}
#endif
