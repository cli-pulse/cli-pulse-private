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
            DataRefreshManager.needsFolderAccessNudge(
                scanIsEmpty: true,
                isSandboxed: false,
                // Worst case for the guard: every root reads as unbookmarked,
                // which is exactly what an unsandboxed build always reports.
                missingRoots: { _ in Self.allRootsMissing }
            ),
            "an unsandboxed build needs no bookmarks — an empty scan there means no CLI usage, not blocked access"
        )
    }

    /// The sandboxed case must still fire, or the guard above would have
    /// silently disabled the banner for the users who actually need it —
    /// the MAS install where the sandbox really is holding the data back.
    /// Pairing this with the test above makes a constant implementation
    /// fail one of them.
    func testSandboxedBuildWithNoBookmarksIsNudged() {
        XCTAssertTrue(
            DataRefreshManager.needsFolderAccessNudge(
                scanIsEmpty: true,
                isSandboxed: true,
                missingRoots: { _ in Self.allRootsMissing }
            ),
            "a sandboxed build with no bookmarks and an empty scan is exactly who the banner is for"
        )
    }

    /// A sandboxed user who HAS granted access but still scans empty has
    /// nothing to grant — they simply have no CLI usage yet. Nudging them
    /// would send them to a Settings panel where everything is already
    /// checked off. This is the branch the sandbox guard must not swallow.
    func testSandboxedBuildWithAccessAlreadyGrantedIsNotNudged() {
        XCTAssertFalse(
            DataRefreshManager.needsFolderAccessNudge(
                scanIsEmpty: true,
                isSandboxed: true,
                missingRoots: { _ in [] }
            ),
            "access is already granted — an empty scan here means no CLI usage, not blocked access"
        )
    }

    /// A non-empty scan means data is already flowing; nothing to nudge
    /// about, regardless of sandbox status or bookmark state.
    func testScanThatProducedDataNeverNudges() {
        for sandboxed in [true, false] {
            XCTAssertFalse(
                DataRefreshManager.needsFolderAccessNudge(
                    scanIsEmpty: false,
                    isSandboxed: sandboxed,
                    missingRoots: { _ in Self.allRootsMissing }
                ),
                "data is flowing (isSandboxed=\(sandboxed)) — asking for folder access here would be noise"
            )
        }
    }

    func testNoSelectedCostProviderNeverRequestsFolderAccess() {
        XCTAssertFalse(
            DataRefreshManager.needsFolderAccessNudge(
                scanIsEmpty: true,
                allowedProviders: [],
                isSandboxed: true,
                missingRoots: { _ in Self.allRootsMissing }
            )
        )
    }

    /// Stand-in for "no bookmark covers any scan root". Injected rather than
    /// read for real: `CostUsageScanner.missingScanRoots()` goes through
    /// `BookmarkManager`, which reads the shared app-group suite
    /// `group.yyh.CLI-Pulse` — i.e. whatever the developer's own installed
    /// copy of CLI Pulse holds. Letting that leak in would make these tests
    /// pass on an unsandboxed DEVID machine and fail on one where MAS has
    /// been granted access.
    private static let allRootsMissing = [
        "/Users/test/.claude", "/Users/test/.config/claude",
        "/Users/test/.codex", "/Users/test/.config/codex"
    ]
}
#endif
