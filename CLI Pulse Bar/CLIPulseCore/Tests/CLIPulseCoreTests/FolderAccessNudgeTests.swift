#if os(macOS)
import XCTest
@testable import CLIPulseCore

/// v1.44 W1: pin `DataRefreshManager.needsFolderAccessNudge`.
///
/// The banner it drives asks the user to grant access to their home folder.
/// That is a heavyweight ask, so the predicate has to be right in both
/// directions — a false negative costs a sandboxed user all of their data,
/// a false positive tells an unsandboxed user something untrue about their
/// own machine.
@MainActor
final class FolderAccessNudgeTests: XCTestCase {

    /// The regression this exists for. Security-scoped bookmarks are an App
    /// Sandbox mechanism; an unsandboxed Developer ID build reads the scan
    /// roots directly and never stores one, so `missingScanRoots()` reports
    /// every root as unbookmarked there. Concluding "access is blocked" from
    /// that is simply wrong.
    ///
    /// Pre-W1 the bug was masked on Overview by an `isAuthenticated &&` gate
    /// that no unauthenticated user got past. W1 makes the unauthenticated
    /// first launch the default path, so a DEVID user who has never run
    /// Claude or Codex would have been told to hand over their home folder
    /// when the real state is "no CLI usage yet".
    ///
    /// RED against pre-W1 `needsFolderAccessNudge`, which had no sandbox
    /// guard and returned true here.
    func testUnsandboxedBuildIsNeverNudgedForFolderAccess() {
        XCTAssertFalse(
            DataRefreshManager.needsFolderAccessNudge(scanIsEmpty: true, isSandboxed: false),
            "an unsandboxed build needs no bookmarks — an empty scan there means no CLI usage, not blocked access"
        )
    }

    /// The sandboxed case must still fire, or the guard above would have
    /// silently disabled the banner for the users who actually need it —
    /// the MAS install where the sandbox really is holding the data back.
    /// Pairing this with the test above makes a constant implementation
    /// fail one of them.
    func testSandboxedBuildWithNoBookmarksIsNudged() {
        // The test process stores no security-scoped bookmarks, so every
        // scan root reads as missing — the same state a fresh MAS install
        // is in before the user grants access.
        XCTAssertFalse(
            CostUsageScanner.missingScanRoots().isEmpty,
            "precondition: the test process holds no bookmarks"
        )
        XCTAssertTrue(
            DataRefreshManager.needsFolderAccessNudge(scanIsEmpty: true, isSandboxed: true),
            "a sandboxed build with no bookmarks and an empty scan is exactly who the banner is for"
        )
    }

    /// A non-empty scan means data is already flowing; nothing to nudge
    /// about, regardless of sandbox status or bookmark state.
    func testScanThatProducedDataNeverNudges() {
        XCTAssertFalse(
            DataRefreshManager.needsFolderAccessNudge(scanIsEmpty: false, isSandboxed: true),
            "data is flowing — asking for folder access here would be noise"
        )
        XCTAssertFalse(
            DataRefreshManager.needsFolderAccessNudge(scanIsEmpty: false, isSandboxed: false),
            "data is flowing — asking for folder access here would be noise"
        )
    }
}
#endif
