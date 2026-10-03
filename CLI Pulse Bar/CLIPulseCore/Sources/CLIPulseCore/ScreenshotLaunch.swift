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
/// - **Opens the requested screen.** `cost` is the Overview tab scrolled so it
///   opens on the Activity card, with the Cost Summary and Provider Usage below
///   it. Through 1.55's first reshoot it scrolled the Cost Summary to the top,
///   as the 1.53.0 `03_cost` shot did; once Top Projects and Risk Signals
///   stopped drawing for accounts with no rows (#614), and Gemini had no cost
///   rows, that left more than half of the screen blank. Scrolled to the very
///   end instead, it repeated nearly all of the `overview` shot.
/// - **No network, structurally.** The app runs under
///   `CLIPulseRuntimeEnvironment.restrictedForScreenshotCapture()`: every
///   capability off, no session restore, and an API client pointed at
///   `127.0.0.1:0`. A signed-in account on the same simulator is never read.
/// - **No permission prompt.** The Alerts tab normally asks for notification
///   permission when it appears; a capture never does (see `iOSAlertsTab`).
/// - **READY means the screen is showing.** The line the script waits for is
///   printed only if `state.selectedTab` is the requested tab AND that tab's
///   screen reports itself on screen (`ShowsTab`, `ShownTabs`). The second
///   half is what makes it true on iPad: its split view once kept a selection
///   of its own that started on the Overview, so every iPad capture showed the
///   Overview while `selectedTab`, the only thing READY then checked, named
///   the requested tab.
///
/// The same launch captures the iPhone set and the iPad set; which one depends
/// only on the simulator it runs on.
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
            self == .cost ? .activity : nil
        }

        /// Whether the screen opens a session beside the list, where the layout
        /// has room for one: the iPad's Sessions tab is a list and a detail
        /// pane, and until a session is picked the pane says "Select a
        /// session". Its rows carry name, provider, project and status; the
        /// usage, cost and requests the set's caption names are in the
        /// detail, one tap away for anyone. The iPhone's rows show them, and
        /// its Sessions tab has no pane, so this changes nothing there.
        public var opensSessionDetail: Bool {
            self == .sessions
        }
    }

    /// The session a capture opens beside the list (`opensSessionDetail`):
    /// the most recently active one of the Active section. Demo's newest three
    /// share one timestamp, and a sort promises no order among equals, so of
    /// those the first in the list is taken: the same session in every
    /// language and every run.
    public static func sessionToOpen(in sessions: [SessionRecord], now: Date) -> SessionRecord? {
        let active = SessionFreshnessTierClassifier.partition(sessions, now: now).active
        let ids = Set(active.map(\.id))
        let newest = active.compactMap { sharedISO8601Parse($0.last_active_at) }.max()
        return sessions.first { ids.contains($0.id) && sharedISO8601Parse($0.last_active_at) == newest }
    }

    /// A view a capture scrolls to. Tagged in the view with `.id(target)`.
    public enum ScrollTarget: String, Hashable, Sendable {
        /// The Overview's Activity card. At the top of the screen it leaves
        /// room for the Cost Summary and Provider Usage below it and repeats
        /// none of the metric tiles the `overview` shot opens with.
        case activity
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
    /// tab) and `shown`, the tabs whose screens report themselves on screen
    /// (`ShownTabs`), is exactly the requested tab. Otherwise an ERROR naming
    /// what is on screen instead, so a later change that resets the tab, leaves
    /// Demo after launch, or shows another screen than `selectedTab` names
    /// stops the capture rather than filing the wrong screen under this one's
    /// name.
    @MainActor
    public static func readinessLine(for request: Request, state: AppState,
                                     shown: Set<AppState.Tab>) -> String {
        var wrong: [String] = []
        let tab = request.screen.tab
        if !state.isDemoMode { wrong.append("not in Demo mode") }
        if !state.isAuthenticated { wrong.append("not signed in") }
        if state.selectedTab != tab {
            wrong.append("on the \(state.selectedTab.rawValue) tab, not \(tab.rawValue)")
        }
        if shown != [tab] {
            let names = shown.map(\.rawValue).sorted().joined(separator: " and ")
            let showing = shown.isEmpty ? "no tab's screen"
                : "the \(names) screen" + (shown.count == 1 ? "" : "s")
            wrong.append("showing \(showing), not \(tab.rawValue)")
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
    /// Overview's scroll to the Activity card and SwiftUI's first layout passes;
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
                ScreenshotLaunch.emit(ScreenshotLaunch.readinessLine(
                    for: request, state: state, shown: ShownTabs.shared.tabs))
            }
        }
    }

    /// Which tabs' screens are showing, as the screens report it themselves
    /// (`ShowsTab`). Counted, not a flag per tab: a layout may briefly hold
    /// two copies of one screen, and the first to go must not take the other
    /// with it.
    @MainActor
    public final class ShownTabs {
        /// The app's, which `ShowsTab` writes and `ReadySignal` reads.
        public static let shared = ShownTabs()

        private var counts: [AppState.Tab: Int] = [:]

        public init() {}

        public func appeared(_ tab: AppState.Tab) {
            counts[tab, default: 0] += 1
        }

        public func disappeared(_ tab: AppState.Tab) {
            counts[tab] = max(0, counts[tab, default: 0] - 1)
        }

        /// The tabs with a screen showing now.
        public var tabs: Set<AppState.Tab> {
            Set(counts.filter { $0.value > 0 }.map(\.key))
        }
    }

    /// Reports the screen it is attached to as `tab`'s while it is on screen
    /// (`ShownTabs.shared`). Attach it to each tab's screen, inside whatever
    /// decides which screen shows, never outside it: a marker on the container
    /// would report the selection, which is the very thing it checks.
    public struct ShowsTab: ViewModifier {
        private let tab: AppState.Tab

        public init(_ tab: AppState.Tab) {
            self.tab = tab
        }

        public func body(content: Content) -> some View {
            content
                .onAppear { ShownTabs.shared.appeared(tab) }
                .onDisappear { ShownTabs.shared.disappeared(tab) }
        }
    }

    /// Scrolls the enclosing `ScrollView` to the requested screen's target, if
    /// the target is in this content. Attach inside the `ScrollView`.
    public struct ScrollToTarget: ViewModifier {
        /// Blank space added below the content during a capture that scrolls.
        /// The target is near the end of the Overview, so the scroll stopped
        /// at the bottom with the card above it cut in half under the
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
