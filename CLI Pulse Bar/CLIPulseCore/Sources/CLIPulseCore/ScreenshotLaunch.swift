#if DEBUG
import Foundation
import SwiftUI

/// App Store screenshot capture without a single tap. DEBUG builds only.
///
/// Every line of this file, and every call site of it in the iPhone app, sits
/// inside `#if DEBUG`, so a Release build (the one App Review and customers
/// get) contains neither these argument names nor this behaviour.
/// `CLI Pulse Bar/scripts/capture_ios_screenshots.sh` drives it;
/// `ScreenshotLaunchTests` holds every use of it in the app to `#if DEBUG`.
///
///     -CLIPulseScreenshotDemo YES -CLIPulseScreenshotScreen providers
///
/// The 1.53.0 iPhone screenshots were taken by hand: Try Demo, tap a tab,
/// scroll, capture, once per screen per language. Two languages took an
/// afternoon; six would take three, and a hand-scrolled "cost" screen never
/// lands in the same place twice. A launch like the one above lands on the
/// same screen every time, in whatever language `-AppleLanguages` names.
///
/// What a capture launch does, and why each part:
///
/// - **Demo mode through `enterDemoMode()`**, the call Try Demo makes, so every
///   number on screen comes from `DemoDataProvider` like it does for any
///   reviewer who taps Try Demo. Nothing here fabricates data of its own.
/// - **Opens the requested screen.** `cost` is the Overview tab scrolled to its
///   Cost Summary, which is what the 1.53.0 `03_cost` shot showed.
/// - **No network, structurally.** The app runs under
///   `CLIPulseRuntimeEnvironment.restrictedForScreenshotCapture()`: every
///   capability off, no session restore, and an API client pointed at
///   `127.0.0.1:0`. A signed-in account on the same simulator is never read.
/// - **No permission prompt.** The Alerts tab normally asks for notification
///   permission when it appears; a capture never does (see `iOSAlertsTab`).
public enum ScreenshotLaunch {
    public static let demoArgument = "-CLIPulseScreenshotDemo"
    public static let screenArgument = "-CLIPulseScreenshotScreen"

    /// Written to stdout once the requested screen has had time to lay out,
    /// and only if the app is on it (see `readinessLine`). The capture script
    /// waits for it instead of guessing with a sleep.
    public static let readyMarker = "CLIPULSE_SCREENSHOT_READY"
    /// Written to stdout when the arguments are wrong (before exiting), or
    /// when the app is not on the requested screen when it would be ready.
    public static let errorMarker = "CLIPULSE_SCREENSHOT_ERROR"

    /// The screens of the App Store set, in listing order. The capture script
    /// names the same five in the same order; `ScreenshotLaunchTests` fails
    /// if the two drift.
    public enum Screen: String, CaseIterable, Sendable {
        case overview
        case providers
        case cost
        case sessions
        case alerts

        /// The tab the screen lives on.
        public var tab: AppState.Tab {
            switch self {
            case .overview, .cost: return .overview
            case .providers: return .providers
            case .sessions: return .sessions
            case .alerts: return .alerts
            }
        }

        /// Where the tab is scrolled to, if anywhere.
        public var scrollTarget: ScrollTarget? {
            self == .cost ? .costSummary : nil
        }
    }

    /// A view a capture scrolls to. Tagged in the view with `.id(target)`.
    public enum ScrollTarget: String, Hashable, Sendable {
        case costSummary
    }

    public struct Request: Equatable, Sendable {
        public let screen: Screen

        public init(screen: Screen) {
            self.screen = screen
        }
    }

    public enum Parsed: Equatable, Sendable {
        /// No capture argument: a normal launch.
        case notRequested
        case request(Request)
        /// A capture argument that cannot be honoured. A capture that silently
        /// fell back to a normal launch would photograph the sign-in screen and
        /// call it "providers", so this is an error, not a default.
        case invalid(String)
    }

    /// Reads the capture arguments out of a process's arguments. Pure.
    ///
    /// - `-CLIPulseScreenshotDemo` takes a boolean the way `UserDefaults` spells
    ///   one: YES/NO, true/false, 1/0, in any case. NO is a normal launch.
    /// - `-CLIPulseScreenshotScreen` takes one of `Screen`'s raw values and
    ///   needs `-CLIPulseScreenshotDemo YES`. Without it the screen is Overview.
    /// - Either flag without a value, with a value it does not know, or given
    ///   twice is `.invalid`. Every other argument (`-AppleLanguages`, the
    ///   executable path, …) is ignored.
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
        guard let enabled = boolValue(demoValue) else {
            return .invalid("\(demoArgument) takes YES or NO, not '\(demoValue)'")
        }
        guard enabled else {
            if let screenValue {
                return .invalid("\(screenArgument) \(screenValue) needs \(demoArgument) YES")
            }
            return .notRequested
        }
        guard let screenValue else {
            return .request(Request(screen: .overview))
        }
        guard let screen = Screen(rawValue: screenValue) else {
            let known = Screen.allCases.map(\.rawValue).joined(separator: ", ")
            return .invalid("\(screenArgument) '\(screenValue)' is not one of: \(known)")
        }
        return .request(Request(screen: screen))
    }

    private static func boolValue(_ raw: String) -> Bool? {
        switch raw.lowercased() {
        case "yes", "true", "1": return true
        case "no", "false", "0": return false
        default: return nil
        }
    }

    /// This process's capture request, read once.
    public static let current: Parsed = parse(ProcessInfo.processInfo.arguments)

    /// The request this process is running, or nil for a normal launch.
    public static var activeRequest: Request? {
        if case .request(let request) = current { return request }
        return nil
    }

    /// The request to run, nil for a normal launch; exits the process with a
    /// marked message when the arguments are wrong. For the app's entry point.
    public static func requestOrExit() -> Request? {
        switch current {
        case .notRequested:
            return nil
        case .request(let request):
            return request
        case .invalid(let reason):
            emit("\(errorMarker) \(reason)")
            exit(64)   // EX_USAGE
        }
    }

    /// Puts `state` on the requested screen, in Demo mode.
    @MainActor
    public static func apply(_ request: Request, to state: AppState) {
        state.enterDemoMode()
        state.selectedTab = request.screen.tab
    }

    /// The line the capture script waits for: READY only if `state` is still
    /// what `apply` made it (Demo mode, signed in to it, on the requested
    /// tab). Otherwise an ERROR naming what is on screen instead, so a later
    /// change that resets the tab or leaves Demo after launch stops the
    /// capture rather than filing the wrong screen under this one's name.
    @MainActor
    public static func readinessLine(for request: Request, state: AppState) -> String {
        var wrong: [String] = []
        if !state.isDemoMode { wrong.append("not in Demo mode") }
        if !state.isAuthenticated { wrong.append("not signed in") }
        if state.selectedTab != request.screen.tab {
            wrong.append("on the \(state.selectedTab.rawValue) tab, not \(request.screen.tab.rawValue)")
        }
        guard wrong.isEmpty else {
            return "\(errorMarker) \(request.screen.rawValue): \(wrong.joined(separator: "; "))"
        }
        return "\(readyMarker) \(request.screen.rawValue)"
    }

    /// Unbuffered: `print` is block-buffered when stdout is a file, which is
    /// exactly how `simctl launch --stdout=` hands it to the script.
    static func emit(_ line: String) {
        FileHandle.standardOutput.write(Data((line + "\n").utf8))
    }

    /// How long after the first frame the screen is declared ready. Covers the
    /// Overview's scroll to the Cost Summary and SwiftUI's first layout passes;
    /// the capture script waits a further settle interval of its own.
    static let readyDelay: TimeInterval = 1.5
}

// MARK: - Views

extension ScreenshotLaunch {
    /// Announces the requested screen, once, after `readyDelay`: READY if
    /// the app is on it, ERROR if not (`readinessLine`). Attach to the app's
    /// root view.
    public struct ReadySignal: ViewModifier {
        private let state: AppState

        public init(state: AppState) {
            self.state = state
        }

        public func body(content: Content) -> some View {
            content.task {
                guard let request = ScreenshotLaunch.activeRequest else { return }
                try? await Task.sleep(nanoseconds: UInt64(ScreenshotLaunch.readyDelay * 1_000_000_000))
                ScreenshotLaunch.emit(ScreenshotLaunch.readinessLine(for: request, state: state))
            }
        }
    }

    /// Scrolls the enclosing `ScrollView` to the requested screen's target, if
    /// the target is in this content. Attach inside the `ScrollView`.
    public struct ScrollToTarget: ViewModifier {
        /// Blank space added below the content during a capture that scrolls.
        /// The Cost Summary is near the end of the Overview, so the scroll
        /// stopped at the bottom with the card above it cut in half under the
        /// navigation bar. With this room the target reaches the top.
        static let tailRoom: CGFloat = 800

        public init() {}

        public func body(content: Content) -> some View {
            let target = ScreenshotLaunch.activeRequest?.screen.scrollTarget
            ScrollViewReader { proxy in
                content
                    .padding(.bottom, target == nil ? 0 : Self.tailRoom)
                    .task {
                        guard let target else { return }
                        // One layout pass first: scrolling to a view that has
                        // not been measured yet does nothing.
                        try? await Task.sleep(nanoseconds: 300_000_000)
                        proxy.scrollTo(target, anchor: .top)
                    }
            }
        }
    }
}
#endif
