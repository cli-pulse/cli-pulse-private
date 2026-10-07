#if DEBUG
import Foundation

/// The Apple Watch App Store screenshots, without a tap. DEBUG builds only.
///
/// The Watch's sibling of `ScreenshotLaunch`, with the same two arguments and
/// the same markers:
///
///     -CLIPulseScreenshotDemo YES -CLIPulseScreenshotScreen quota
///
/// `CLI Pulse Bar/scripts/capture_ios_screenshots.sh --set watch` drives it on
/// the Apple Watch Ultra 3 simulator, one launch per page and language.
/// Everything here, and every call of it in the Watch app, is inside
/// `#if DEBUG`, so the Watch app App Review and customers get has neither the
/// arguments nor the behaviour (`WatchScreenshotLaunchTests`).
///
/// Until 1.56 the Watch set was drawn by an AppKit script
/// (`generate_watch_screenshots.swift`) with figures of its own ($146.03
/// today, a "Usage spike" alert no producer raises), and the set on the store
/// was older still. A capture launch draws the Watch app's own pages from
/// Demo's data instead.
///
/// What a capture launch does:
///
/// - **Demo's data, as this Watch's own refresh would hold it.** A Watch never
///   sees the phone's Demo: the phone relays nothing until a real sign-in
///   (`PhoneSessionManager` needs an identity), and the Watch's Demo flag
///   fetches from the cloud like any account. So `demoSnapshot` takes the
///   account Demo describes (`DemoDataProvider`, which follows production,
///   #650) and maps it the way `WatchAppState.refreshAll` maps the cloud's
///   rows: the dashboard through `APIClient.dashboardSummary(from:)` (no
///   requests, no hourly trend, no recent activity, no top projects), the
///   providers through `QuotaBindingCap.projectedForDisplay` from the legacy
///   provider summary (the v2 read flag is off in every build), the device
///   health cards through `WatchDeviceTrim`, and each list in the order its
///   REST query asks for.
/// - **Opens the requested page** of the Watch's pager.
/// - **No network.** The capture never restores a session, never activates
///   WatchConnectivity and never refreshes (`WatchAppState`).
/// - **READY means the page is showing**: the requested page is the pager's
///   selection and has appeared (`readinessLine`).
public enum WatchScreenshotLaunch {
    public static let demoArgument = ScreenshotLaunch.demoArgument
    public static let screenArgument = ScreenshotLaunch.screenArgument
    public static let readyMarker = ScreenshotLaunch.readyMarker
    public static let errorMarker = ScreenshotLaunch.errorMarker

    /// The pages of the Watch set, in listing order: the four pages of the
    /// Watch's pager (`WatchTab`). The capture script's WATCH_SCREENS names
    /// the same four in the same order.
    public enum Screen: String, CaseIterable, Sendable {
        case pulse
        case quota
        case live
        case alerts
    }

    public enum Parsed: Equatable, Sendable {
        /// No capture argument: a normal launch.
        case notRequested
        case request(Screen)
        /// A capture argument that cannot be honoured: an error, never a
        /// normal launch filed under a page's name.
        case invalid(String)
    }

    /// Reads the capture arguments, by `ScreenshotLaunch.parse`'s rules:
    /// `-CLIPulseScreenshotDemo` takes YES/NO (true/false, 1/0, any case),
    /// `-CLIPulseScreenshotScreen` one of `Screen`'s raw values and needs
    /// `-CLIPulseScreenshotDemo YES` (without it the page is Pulse); either
    /// flag without a value, with a value it does not know, or given twice is
    /// `.invalid`. Every other argument is ignored. Pure.
    public static func parse(_ arguments: [String]) -> Parsed {
        var demoValue: String?
        var screenValue: String?
        var index = arguments.startIndex
        while index < arguments.endIndex {
            let argument = arguments[index]
            guard argument == demoArgument || argument == screenArgument else {
                index += 1
                continue
            }
            let valueIndex = index + 1
            guard valueIndex < arguments.endIndex else {
                return .invalid("\(argument) needs a value")
            }
            let value = arguments[valueIndex]
            if argument == demoArgument {
                guard demoValue == nil else { return .invalid("\(demoArgument) is given twice") }
                demoValue = value
            } else {
                guard screenValue == nil else { return .invalid("\(screenArgument) is given twice") }
                screenValue = value
            }
            index = valueIndex + 1
        }

        guard let demoValue else {
            if let screenValue {
                return .invalid("\(screenArgument) \(screenValue) needs \(demoArgument) YES")
            }
            return .notRequested
        }
        let enabled: Bool
        switch demoValue.lowercased() {
        case "yes", "true", "1": enabled = true
        case "no", "false", "0": enabled = false
        default: return .invalid("\(demoArgument) takes YES or NO, not '\(demoValue)'")
        }
        guard enabled else {
            if let screenValue {
                return .invalid("\(screenArgument) \(screenValue) needs \(demoArgument) YES")
            }
            return .notRequested
        }
        guard let screenValue else { return .request(.pulse) }
        guard let screen = Screen(rawValue: screenValue) else {
            let known = Screen.allCases.map(\.rawValue).joined(separator: ", ")
            return .invalid("\(screenArgument) '\(screenValue)' is not one of: \(known)")
        }
        return .request(screen)
    }

    /// This process's capture request, read once.
    public static let current: Parsed = parse(ProcessInfo.processInfo.arguments)

    /// The page this process captures, or nil for a normal launch.
    public static var activeScreen: Screen? {
        if case .request(let screen) = current { return screen }
        return nil
    }

    /// The page to capture, nil for a normal launch; exits the process with a
    /// marked message when the arguments are wrong. For the app's entry point.
    public static func screenOrExit() -> Screen? {
        switch current {
        case .notRequested:
            return nil
        case .request(let screen):
            return screen
        case .invalid(let reason):
            emit("\(errorMarker) \(reason)")
            exit(64)   // EX_USAGE
        }
    }

    // MARK: - Demo, as the Watch holds it

    /// What `WatchAppState.refreshAll` stores after a refresh of the account
    /// Demo describes.
    public struct Snapshot {
        public let dashboard: DashboardSummary
        public let providers: [ProviderUsage]
        public let sessions: [SessionRecord]
        public let alerts: [AlertRecord]
        public let devices: [WatchDeviceSummary]
        /// Demo's one refresh (`DemoDataProvider.refreshAge` ago), shown as
        /// the last one.
        public let refreshedAt: Date
    }

    public static func demoSnapshot() -> Snapshot {
        watchSnapshot(of: DemoDataProvider.generate())
    }

    /// The mapping itself, apart from the clock, for the tests.
    static func watchSnapshot(of demo: DemoData) -> Snapshot {
        let d = demo.dashboard
        // The Watch's dashboard is only ever the cloud's `dashboard_summary`
        // row (its own fetch, or the phone relaying the same), so it goes
        // through the same mapping: the five figures the row has, nothing else.
        let dashboard = APIClient.dashboardSummary(from: APIClient.DashboardSummaryPayload(
            today_usage: d.total_usage_today,
            today_cost: d.total_estimated_cost_today,
            active_sessions: d.active_sessions,
            online_devices: d.online_devices,
            unresolved_alerts: d.unresolved_alerts,
            today_sessions: nil
        ))
        // The REST queries' orders (APIClient.sessions/alerts/devices):
        // last_active_at, created_at and last_seen_at, newest first. Stable,
        // so rows with one timestamp keep Demo's order.
        func newestFirst<T>(_ rows: [T], _ key: (T) -> String) -> [T] {
            rows.enumerated().sorted { lhs, rhs in
                let l = sharedISO8601Parse(key(lhs.element)) ?? .distantPast
                let r = sharedISO8601Parse(key(rhs.element)) ?? .distantPast
                return l == r ? lhs.offset < rhs.offset : l > r
            }.map(\.element)
        }
        return Snapshot(
            dashboard: dashboard,
            providers: QuotaBindingCap.projectedForDisplay(demo.providers),
            sessions: newestFirst(demo.sessions) { $0.last_active_at },
            alerts: newestFirst(demo.alerts) { $0.created_at },
            devices: WatchDeviceTrim.summaries(from: newestFirst(demo.devices) { $0.last_sync_at ?? "" }),
            refreshedAt: demo.refreshedAt
        )
    }

    // MARK: - Readiness

    /// READY if the pager's selection is the requested page and that page has
    /// appeared; otherwise an ERROR naming what is wrong, so a change that
    /// resets the pager stops the capture instead of filing another page
    /// under this one's name.
    public static func readinessLine(for screen: Screen, selected: Screen, appeared: Set<Screen>) -> String {
        var wrong: [String] = []
        if selected != screen { wrong.append("the pager is on \(selected.rawValue), not \(screen.rawValue)") }
        if !appeared.contains(screen) { wrong.append("the \(screen.rawValue) page never appeared") }
        guard wrong.isEmpty else {
            return "\(errorMarker) \(screen.rawValue): \(wrong.joined(separator: "; "))"
        }
        return "\(readyMarker) \(screen.rawValue)"
    }

    /// How long after launch the page is declared ready: the pager's first
    /// layout and the waveform's first frames. The capture script waits a
    /// settle interval of its own after READY.
    public static let readyDelay: TimeInterval = 2.0

    /// Unbuffered, as `ScreenshotLaunch.emit`.
    public static func emit(_ line: String) {
        FileHandle.standardOutput.write(Data((line + "\n").utf8))
    }
}
#endif
