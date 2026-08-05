import XCTest
@testable import CLIPulseCore

/// The filter that drops "the user is holding the menu-bar button down" hangs.
///
/// A filter like this earns its keep only if it is shown to FIRE on the noise
/// AND to stay out of the way of a real hang. The second half is the one that
/// matters: a filter that silently eats a genuine main-thread block is strictly
/// worse than no filter, because it converts a visible problem into an
/// invisible one.
final class BenignModalTrackingHangTests: XCTestCase {

    /// Verbatim from Sentry issue 7532620959, event of 2026-08-04T16:06 on
    /// `cli-pulse@1.44.0+97` — the top macOS "hang", 15 users. Oldest-first.
    private let realWorldNoiseStack = [
        "start",
        "main",
        "CLIPulseBarApp.$main",
        "App.main",
        "runApp<T>",
        "runApp",
        "NSApplicationMain",
        "-[NSApplication run]",
        "-[NSApplication _handleEvent:]",
        "-[NSApplication(NSEventRouting) sendEvent:]",
        "-[NSStatusBarWindow sendEvent:]",
        "-[NSWindow(NSEventRouting) sendEvent:]",
        "-[NSWindow(NSEventRouting) _reallySendEvent:isDelayedEvent:]",
        "-[NSWindow(NSEventRouting) _handleMouseDownEvent:isDelayedEvent:]",
        "-[NSStatusBarButtonCell trackMouse:inRect:ofView:untilMouseUp:]",
        "-[NSButtonCell trackMouse:inRect:ofView:untilMouseUp:]",
        "-[NSCell trackMouse:inRect:ofView:untilMouseUp:]",
        "NSControlTrackMouse",
        "-[NSDragEventTracker trackEvent:usingHandler:]",
        "-[NSWindow(NSEventRouting) trackEventsMatchingMask:timeout:mode:handler:]",
        "-[NSApplication(NSEventRouting) _nextEventMatchingEventMask:untilDate:inMode:dequeue:]",
        "_DPSNextEvent",
        "_BlockUntilNextEventMatchingListInModeWithFilter",
        "ReceiveNextEventCommon",
        "RunCurrentEventLoopInMode",
        "CFRunLoopRunSpecific",
        "__CFRunLoopRun",
        "__CFRunLoopServiceMachPort",
        "mach_msg",
        "mach_msg_overwrite",
        "mach_msg2_internal",
        "mach_msg2_trap",
    ]

    func test_realWorldNoiseStackIsRecognised() {
        XCTAssertTrue(SentryLogger.isBenignModalTrackingStack(realWorldNoiseStack))
    }

    // MARK: - The half that matters: real hangs survive

    /// The exact bug class this filter must never hide. Three production hangs
    /// were synchronous XPC on the main thread; one of them
    /// (`NSWorkspace.open` in `HelperInstaller.install()`) fired from a click,
    /// so its stack ALSO sits under a mouse-tracking frame. What separates it
    /// is the top frame: our call, not a wait.
    func test_syncXPCUnderneathAClickIsKept() {
        let stack = [
            "main",
            "-[NSStatusBarWindow sendEvent:]",
            "-[NSStatusBarButtonCell trackMouse:inRect:ofView:untilMouseUp:]",
            "NSControlTrackMouse",
            "HelperInstaller.install()",
            "-[NSWorkspace openURL:]",
            "_LSOpenURLsWithRole",
            "xpc_connection_send_message_with_reply_sync",
        ]
        XCTAssertFalse(
            SentryLogger.isBenignModalTrackingStack(stack),
            "a synchronous XPC call made from a click handler is a REAL hang"
        )
    }

    /// `mach_msg` on top but nothing modal below it: a plain blocking IPC wait,
    /// e.g. the keychain hang. Must be kept.
    func test_machMsgWaitWithoutMouseTrackingIsKept() {
        let stack = [
            "main",
            "KeychainHelper.load(key:)",
            "SecItemCopyMatching",
            "mach_msg2_trap",
        ]
        XCTAssertFalse(SentryLogger.isBenignModalTrackingStack(stack))
    }

    /// Mouse tracking present, but the thread is running our code rather than
    /// waiting — the drag handler itself is slow. Real, and actionable.
    func test_workRunningInsideTheTrackingLoopIsKept() {
        let stack = [
            "main",
            "-[NSStatusBarButtonCell trackMouse:inRect:ofView:untilMouseUp:]",
            "NSControlTrackMouse",
            "AppState.publishWidgetData()",
            "CFPrefsPlistSource.sendMessageSettingValues",
        ]
        XCTAssertFalse(SentryLogger.isBenignModalTrackingStack(stack))
    }

    func test_emptyStackIsKept() {
        XCTAssertFalse(SentryLogger.isBenignModalTrackingStack([]))
    }

    /// Truncation to just the wait frames loses the modal marker. Keeping it is
    /// the safe direction: an unexplained hang stays visible.
    func test_waitFramesAloneAreKept() {
        XCTAssertFalse(SentryLogger.isBenignModalTrackingStack(["_DPSNextEvent", "mach_msg2_trap"]))
    }

    // MARK: - Type gate

    func test_appHangTypesAreRecognised() {
        XCTAssertTrue(SentryLogger.isAppHangType("App Hanging"))
        XCTAssertTrue(SentryLogger.isAppHangType("Fatal App Hang Fully Blocked"))
        XCTAssertTrue(SentryLogger.isAppHangType("app hang"))
    }

    /// The filter is scoped to hangs. A crash whose stack happens to sit inside
    /// a tracking loop must never be dropped by it.
    func test_nonHangTypesAreNotRecognised() {
        XCTAssertFalse(SentryLogger.isAppHangType("EXC_BAD_ACCESS"))
        XCTAssertFalse(SentryLogger.isAppHangType("NSInvalidArgumentException"))
        XCTAssertFalse(SentryLogger.isAppHangType(nil))
    }
}
