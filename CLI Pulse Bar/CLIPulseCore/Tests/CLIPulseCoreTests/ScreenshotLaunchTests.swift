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
        XCTAssertEqual(Launch.Screen.cost.tab, .overview, "cost is the Overview scrolled to its Activity card, Cost Summary below")
        XCTAssertEqual(Launch.Screen.providers.tab, .providers)
        XCTAssertEqual(Launch.Screen.sessions.tab, .sessions)
        XCTAssertEqual(Launch.Screen.alerts.tab, .alerts)
        for screen in Launch.Screen.allCases {
            XCTAssertTrue(screen.tab.isVisible, "\(screen) opens a tab the iPhone does not offer")
            XCTAssertEqual(screen.scrollTarget, screen == .cost ? .activity : nil, screen.rawValue)
        }
    }

    /// On iPad the Sessions tab is a list and a detail pane, and its rows show
    /// no usage, cost or requests, which the set's caption promises. A capture
    /// opens the first Active session beside the list; that session has all
    /// three, and nothing red.
    func test_theIPadSessionsScreenOpensTheFirstActiveSession() throws {
        XCTAssertEqual(Launch.Screen.allCases.filter(\.opensSessionDetail), [.sessions])

        let demo = DemoDataProvider.generate()
        let now = Date()
        let opened = try XCTUnwrap(Launch.sessionToOpen(in: demo.sessions, now: now), "no session to open")
        let active = SessionFreshnessTierClassifier.partition(demo.sessions, now: now).active
        XCTAssertTrue(active.contains { $0.id == opened.id }, "one of the Active section")
        XCTAssertEqual(opened.last_active_at, active.map(\.last_active_at).max(), "the most recently active")
        XCTAssertEqual(opened.name, "ios-dashboard", "of Demo's three newest, the first listed, in every run")
        XCTAssertEqual(Launch.sessionToOpen(in: Array(demo.sessions.reversed()), now: now)?.name, "provider-adapters",
                       "the tie is broken by list order, not by whatever order a sort leaves equals in")
        XCTAssertGreaterThan(opened.total_usage, 0, "usage")
        XCTAssertGreaterThan(opened.estimated_cost, 0, "cost")
        XCTAssertGreaterThan(opened.requests, 0, "requests")
        XCTAssertEqual(opened.error_count, 0, "no production session writes errors")

        XCTAssertNil(Launch.sessionToOpen(in: [], now: now), "nothing to open: the pane stays as it is")
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
            XCTAssertEqual(Launch.readinessLine(for: Launch.Request(screen: screen), state: applied(screen),
                                                shown: [screen.tab]),
                           "\(Launch.readyMarker) \(screen.rawValue)")
        }

        let movedAway = applied(.alerts)
        movedAway.selectedTab = .overview
        let line = Launch.readinessLine(for: Launch.Request(screen: .alerts), state: movedAway, shown: [.overview])
        XCTAssertTrue(line.hasPrefix("\(Launch.errorMarker) alerts:"), line)
        XCTAssertTrue(line.contains("on the Overview tab, not Alerts"), line)

        let leftDemo = applied(.providers)
        leftDemo.isDemoMode = false
        leftDemo.isAuthenticated = false
        let left = Launch.readinessLine(for: Launch.Request(screen: .providers), state: leftDemo,
                                        shown: [.providers])
        XCTAssertTrue(left.hasPrefix(Launch.errorMarker), left)
        XCTAssertTrue(left.contains("not in Demo mode") && left.contains("not signed in"), left)
    }

    /// The iPad split view before 1.55: `selectedTab` said Alerts, the screen
    /// showed the Overview, and READY checked only `selectedTab`. READY now
    /// also needs the requested tab's screen to be the one showing, and
    /// nothing else.
    @MainActor
    func test_readyNeedsTheRequestedScreenShowing_notOnlySelected() throws {
        let suite = "ScreenshotLaunchTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        for screen in Launch.Screen.allCases where screen.tab != .overview {
            let state = AppState(
                runtimeEnvironment: productionRuntime.restrictedForScreenshotCapture(),
                defaults: defaults,
                performLaunchSetup: false)
            Launch.apply(Launch.Request(screen: screen), to: state)
            XCTAssertEqual(state.selectedTab, screen.tab, "positive control: the selection is right")

            let line = Launch.readinessLine(for: Launch.Request(screen: screen), state: state, shown: [.overview])
            XCTAssertTrue(line.hasPrefix("\(Launch.errorMarker) \(screen.rawValue):"), line)
            XCTAssertTrue(line.contains("showing the Overview screen, not \(screen.tab.rawValue)"), line)
            XCTAssertFalse(line.contains("on the Overview tab"), "the selection is not what is wrong: \(line)")
        }

        let state = AppState(
            runtimeEnvironment: productionRuntime.restrictedForScreenshotCapture(),
            defaults: defaults,
            performLaunchSetup: false)
        Launch.apply(Launch.Request(screen: .sessions), to: state)
        let request = Launch.Request(screen: .sessions)
        let none = Launch.readinessLine(for: request, state: state, shown: [])
        XCTAssertTrue(none.hasPrefix(Launch.errorMarker) && none.contains("showing no tab's screen"), none)
        let two = Launch.readinessLine(for: request, state: state, shown: [.sessions, .overview])
        XCTAssertTrue(two.hasPrefix(Launch.errorMarker)
                      && two.contains("showing the Overview and Sessions screens, not Sessions"), two)
    }

    @MainActor
    func test_shownTabsCountsEachScreenInAndOut() {
        let shown = Launch.ShownTabs()
        XCTAssertEqual(shown.tabs, [])
        shown.appeared(.overview)
        shown.appeared(.alerts)
        XCTAssertEqual(shown.tabs, [.overview, .alerts])
        shown.disappeared(.overview)
        XCTAssertEqual(shown.tabs, [.alerts])

        // Two copies of one screen: the first to go leaves the other counted.
        shown.appeared(.alerts)
        shown.disappeared(.alerts)
        XCTAssertEqual(shown.tabs, [.alerts])
        shown.disappeared(.alerts)
        XCTAssertEqual(shown.tabs, [])

        // A disappearance with nothing showing does not go below zero, so the
        // next appearance still counts.
        shown.disappeared(.providers)
        shown.appeared(.providers)
        XCTAssertEqual(shown.tabs, [.providers])
    }

    /// The iPad fix, held in the source: neither layout decides on its own
    /// which screen a tab shows, and the iPad keeps no selection of its own.
    ///
    /// iOSMainView.swift is in the iOS app target, which has no test bundle, so
    /// this reads it (like `test_everyUseIsInsideIfDebug`). What it checks at
    /// run time is the READY line above: every capture asserts the screen that
    /// reported itself showing.
    func test_bothIOSLayoutsShowEveryTabThroughTheOneScreenThatReportsIt() throws {
        let source = try String(contentsOf: Self.appSourceRoot
            .appendingPathComponent("CLI Pulse Bar iOS/iOSMainView.swift"), encoding: .utf8)
        func section(from start: String, to end: String?) throws -> String {
            let lower = try XCTUnwrap(source.range(of: start), "no \(start) in iOSMainView.swift").lowerBound
            let rest = source[lower...]
            if let end, let upper = rest.range(of: end)?.lowerBound { return String(rest[..<upper]) }
            return String(rest)
        }
        func matches(_ pattern: String, in text: String) throws -> [[String]] {
            let regex = try NSRegularExpression(pattern: pattern)
            return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).map { m in
                (1..<m.numberOfRanges).map { String(text[Range(m.range(at: $0), in: text)!]) }
            }
        }
        let iOSTabs = ["overview", "providers", "sessions", "alerts", "settings"]

        // The iPhone: every tab of the tab bar is built by iOSTabScreen, for its own tag.
        let iPhone = try section(from: "private var iPhoneTabView", to: "struct iOSTabScreen")
        let built = try matches(#"iOSTabScreen\(tab: \.(\w+)\)"#, in: iPhone).map { $0[0] }
        let tagged = try matches(#"\.tag\(AppState\.Tab\.(\w+)\)"#, in: iPhone).map { $0[0] }
        XCTAssertEqual(built, iOSTabs, "the iPhone's tabs, each through iOSTabScreen")
        XCTAssertEqual(tagged, built, "each built for its own tag")

        // iOSTabScreen: each screen reports the tab it is. Machine and Pet are
        // macOS-only and fall back to the Overview's screen, which says Overview.
        let screen = try section(from: "struct iOSTabScreen", to: "struct iPadSplitView")
        let reported = try matches(
            #"iOS(\w+)Tab\(\)\s*#if DEBUG\s*\.modifier\(ScreenshotLaunch\.ShowsTab\(\.(\w+)\)\)\s*#endif"#,
            in: screen)
        XCTAssertEqual(reported.map { $0[0].lowercased() }, iOSTabs, "every tab's screen, once")
        for pair in reported {
            XCTAssertEqual(pair[1], pair[0].lowercased(), "iOS\(pair[0])Tab reports itself as .\(pair[1])")
        }
        XCTAssertTrue(screen.contains("case .overview, .machine, .pet:"), "the macOS-only tabs fall back to the Overview")

        // The iPad: the sidebar offers the iPhone's tabs, writes the one
        // selection, and the detail is that selection's screen.
        let iPad = try section(from: "struct iPadSplitView", to: nil)
        XCTAssertEqual(try matches(#"sidebarButton\(\s*\.(\w+)"#, in: iPad).map { $0[0] }, iOSTabs)
        XCTAssertTrue(iPad.contains("iOSTabScreen(tab: state.selectedTab)"), "the detail shows the selection's screen")
        XCTAssertTrue(iPad.contains("state.selectedTab = tab"), "the sidebar writes the one selection")
        XCTAssertFalse(iPad.contains("@State"), "a selection of its own is what started every iPad capture on the Overview")
        XCTAssertFalse(iPad.contains("switch "), "a switch here would decide the screen apart from iOSTabScreen")
    }

    /// The iPad's Sessions list draws what the iPhone's does: the Active and
    /// Recent sections and each row's one badge (`SessionStatusBadge`), and so
    /// does the detail beside it. It drew every session in one untitled
    /// section with its raw status, so Demo's five read "Running" next to the
    /// sidebar's "Active Sessions 3", and two of them sat under Recent on the
    /// iPhone panel. The iPad sidebar, like the iPhone's tab bar, puts a count
    /// on Alerts only: Providers had a red "3", the number of providers.
    func test_theIPadSessionsListAndSidebarSayWhatTheIPhoneSays() throws {
        let iOS = Self.appSourceRoot.appendingPathComponent("CLI Pulse Bar iOS")
        let sessions = try String(contentsOf: iOS.appendingPathComponent("iOSSessionsTab.swift"), encoding: .utf8)
        func between(_ start: String, _ end: String, in text: String) throws -> String {
            let lower = try XCTUnwrap(text.range(of: start), "no \(start)").upperBound
            let upper = try XCTUnwrap(text[lower...].range(of: end), "no \(end) after \(start)").lowerBound
            return String(text[lower..<upper])
        }
        let list = try between("private var sessionList", "struct SessionStatusBadge", in: sessions)
        XCTAssertTrue(list.contains("SessionFreshnessTierClassifier.partition(state.sessions"), "the iPad list is not partitioned")
        XCTAssertTrue(list.contains("L10n.sessions.sectionActive") && list.contains("L10n.sessions.sectionRecent"),
                      "the iPad list lost the iPhone's section headers")
        XCTAssertTrue(list.contains("SessionStatusBadge("), "the iPad rows do not use the shared badge")
        XCTAssertFalse(list.contains("L10n.status.localized"), "an iPad row draws a raw status of its own")
        XCTAssertFalse(list.contains("ForEach(state.sessions)"), "the iPad list draws every session unsorted again")
        let row = try between("struct iOSSessionRow", "private func metricItem", in: sessions)
        XCTAssertTrue(row.contains("SessionStatusBadge(session: session, tier: freshnessTier)"), "the iPhone row's badge")
        XCTAssertFalse(row.contains("L10n.status.localized"), "the iPhone row draws a status apart from the shared badge")
        let detail = try between("struct SessionDetailView", "private func detailItem", in: sessions)
        XCTAssertTrue(detail.contains("SessionStatusBadge("), "the detail beside the iPad list badges another way")
        XCTAssertFalse(detail.contains("L10n.status.localized"), "the detail draws a raw status")

        let main = try String(contentsOf: iOS.appendingPathComponent("iOSMainView.swift"), encoding: .utf8)
        let iPad = String(main[try XCTUnwrap(main.range(of: "struct iPadSplitView")).lowerBound...])
        let regex = try NSRegularExpression(pattern: #"sidebarButton\(\s*\.(\w+)\s*,\s*badge:"#)
        let badged = regex.matches(in: iPad, range: NSRange(iPad.startIndex..., in: iPad)).compactMap {
            Range($0.range(at: 1), in: iPad).map { String(iPad[$0]) }
        }
        XCTAssertEqual(badged, ["alerts"], "a sidebar count besides the unresolved alerts")
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
