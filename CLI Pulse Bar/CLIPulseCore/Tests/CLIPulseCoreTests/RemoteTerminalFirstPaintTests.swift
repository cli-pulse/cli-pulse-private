// Guards for the three defects that made the iPhone's remote terminal a
// black rectangle while its own status bar read "Connected", measured on
// an iPhone 17 Pro simulator against a real LANLinkAgent on 2026-09-05.
//
// Two of the three live in `RemoteTerminalView`, which is `#if os(iOS) ||
// os(visionOS)`. CI builds the iOS scheme but runs no iOS tests, so a
// behavioural test there would be a guard that never runs — the mistake
// this repo has already paid for. They are pinned as SOURCE guards, which
// do run, and the third (the one that is reachable from macOS) gets a
// real behavioural test.
import XCTest
@testable import CLIPulseCore

final class RemoteTerminalFirstPaintTests: XCTestCase {

    private func coreSource(_ name: String) throws -> String {
        let here = URL(fileURLWithPath: #filePath)          // …/Tests/CLIPulseCoreTests/<this>
        let root = here.deletingLastPathComponent()         // …/Tests/CLIPulseCoreTests
            .deletingLastPathComponent()                    // …/Tests
            .deletingLastPathComponent()                    // …/CLIPulseCore
        return try String(contentsOf: root.appending(path: "Sources/CLIPulseCore/\(name)"),
                          encoding: .utf8)
    }

    /// DEFECT 1 — the lost first paint.
    ///
    /// `window.pushChunk` is defined by the page's own script, so a push
    /// before `loadFileURL` completes evaluates against a blank document
    /// and is dropped with no error (there is no completion handler). The
    /// iOS host fires that first push synchronously from `makeUIView`,
    /// four lines after constructing the view, so it ALWAYS lands in that
    /// window — and nothing re-sends: `isReady` has no reader on iOS,
    /// `ReattachPaintBuffer.flush` is one-shot, and unlike the Mac's
    /// `TerminalSessionAdapter` nothing re-pushes geometry on ready to
    /// force a TUI repaint. Hence: black forever.
    func test_outputIsHeldUntilThePageCanReceiveIt() throws {
        let src = try coreSource("RemoteTerminalView.swift")
        XCTAssertTrue(src.contains("guard canEmit else {"),
                      "emitFlush no longer holds output until the page is ready")
        XCTAssertTrue(src.contains("pendingOutput.append(payload)"),
                      "held output is not being buffered")
        XCTAssertTrue(src.contains("self.drainPendingOutput()"),
                      "the ready handler no longer replays what it held")
        // Order matters: the held bytes must reach the terminal BEFORE the
        // delegate acts on didBecomeReady.
        let drain = try XCTUnwrap(src.range(of: "self.drainPendingOutput()"))
        let notify = try XCTUnwrap(src.range(of: "self.delegate?.remoteTerminalViewDidBecomeReady(self)"))
        XCTAssertTrue(drain.lowerBound < notify.lowerBound,
                      "the delegate is told ready before the held output is replayed")
        XCTAssertTrue(src.contains("pendingOutputCap"),
                      "the hold buffer is unbounded — a page that never loads would leak")
    }

    /// DEFECT 2 — `clear()` guarded on a global the page never defines.
    ///
    /// The page exports `window.__CLIPulseTerminal.term` and never assigns
    /// `window.term`, so `if (window.term)` was always false and switching
    /// sessions wiped nothing: session A's output stayed on screen under
    /// session B, the exact thing `clear()` exists to prevent.
    func test_clearTargetsTheGlobalThePageActuallyDefines() throws {
        let view = try coreSource("RemoteTerminalView.swift")
        XCTAssertFalse(view.contains("window.term)"),
                       "clear() is guarded on window.term again, which the page never assigns")
        XCTAssertTrue(view.contains("window.__CLIPulseTerminal.term.reset()"),
                      "clear() no longer resets the terminal the page exports")

        let page = try coreSource("Resources/Terminal/index.html")
        XCTAssertTrue(page.contains("window.__CLIPulseTerminal"),
                      "the page stopped exporting __CLIPulseTerminal — clear() now targets nothing")
        XCTAssertFalse(page.contains("window.term ="),
                       "the page now DOES define window.term; re-check which global clear() should use")
    }
}
