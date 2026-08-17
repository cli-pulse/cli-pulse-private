#if os(macOS)
import AppKit
import XCTest
@testable import CLIPulseCore

/// The decision logic is covered by `FirstRunPresentationTests`. This covers the
/// part that logic cannot: whether a window actually appears, at a size a human
/// can read.
///
/// That distinction matters here more than usual. A zero-size or off-screen
/// window is indistinguishable, to the user AND to every counter we have, from
/// no window at all — which is the exact defect this feature exists to remove,
/// reintroduced one level down. `NSHostingView.fittingSize` really does return
/// zero before the view has been in a window, so this is a live failure mode
/// rather than a hypothetical one.
@MainActor
final class FirstRunWelcomeControllerTests: XCTestCase {

    private func makeController() -> FirstRunWelcomeController {
        // A fresh instance, never `.shared` — a test that drove the singleton
        // would leave a window attached to it for every later test in the run.
        let controller = FirstRunWelcomeController()
        addTeardownBlock { @MainActor in controller.dismiss() }
        return controller
    }

    func testPresentCreatesAVisibleWindow() {
        let controller = makeController()
        XCTAssertFalse(controller.isVisible)

        controller.present()

        XCTAssertTrue(controller.isVisible, "present() produced no window")
    }

    func testWindowIsLargeEnoughToRead() throws {
        let controller = makeController()
        controller.present()

        let window = try XCTUnwrap(
            NSApplication.shared.windows.first {
                $0.title == L10n.firstRun.title && $0.isVisible
            },
            "no window carrying the first-run title"
        )
        // The fallback alone is 420x300; a real layout should be in that region.
        // Anything tiny means fittingSize came back degenerate and the fallback
        // did not catch it.
        XCTAssertGreaterThanOrEqual(window.frame.width, 200)
        XCTAssertGreaterThanOrEqual(window.frame.height, 120)
    }

    func testWindowIsClosableByTheUser() throws {
        // A brand-new user who does not trust the button must still have the
        // ordinary way out. A greeting window that traps them is worse than none.
        let controller = makeController()
        controller.present()

        let window = try XCTUnwrap(
            NSApplication.shared.windows.first {
                $0.title == L10n.firstRun.title && $0.isVisible
            }
        )
        XCTAssertTrue(window.styleMask.contains(.closable))
        XCTAssertTrue(window.styleMask.contains(.titled))
    }

    func testPresentingTwiceDoesNotStackWindows() {
        let controller = makeController()
        controller.present()
        controller.present()

        // `isVisible`, not merely "exists". Windows created by earlier tests in
        // this process stay in `NSApplication.shared.windows` after `close()`
        // until ARC gets around to deallocating them — `isReleasedWhenClosed` is
        // deliberately false because the controller holds the reference. Counting
        // every window with this title therefore counts ghosts, and the first
        // version of this test failed with 4 for exactly that reason. What a user
        // could actually see is the visible ones.
        let visible = NSApplication.shared.windows.filter {
            $0.title == L10n.firstRun.title && $0.isVisible
        }
        XCTAssertEqual(visible.count, 1, "a second present() stacked another window")
    }

    func testDismissClosesTheWindow() {
        let controller = makeController()
        controller.present()
        XCTAssertTrue(controller.isVisible)

        controller.dismiss()

        XCTAssertFalse(controller.isVisible)
    }

    func testClosingTheWindowDirectlyStillReportsDismissal() throws {
        // The "Got it" button is not the only exit. If the red close button did
        // not run the same callback, the shown-flag would never be written and
        // the window would greet the user again on the next launch — looking
        // broken to the one population it is meant to reassure.
        let controller = makeController()
        var dismissals = 0
        controller.present { dismissals += 1 }

        let window = try XCTUnwrap(
            NSApplication.shared.windows.first {
                $0.title == L10n.firstRun.title && $0.isVisible
            }
        )
        window.close()

        XCTAssertEqual(dismissals, 1, "closing the window did not report a dismissal")
    }
}
#endif
