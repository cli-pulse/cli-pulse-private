import XCTest
@testable import CLIPulseCore

/// A4 (2026-08-30) — the Swarm tab is hidden.
///
/// It was a top-level tab on macOS and iOS that could never contain
/// anything. Swarm rows arrive via `remote_helper_swarm_heartbeat`, and no
/// shipped helper calls it: `HelperSwift/Sources/` has two comment mentions
/// and no producer, and the only caller anywhere is
/// `helper/cli_pulse_helper.py:483`, behind a `swarm_enabled = False` that
/// nothing sets. Production `remote_swarms` is 0 rows.
///
/// v1.22.0's release notes said it was dark-shipped. It was not — the macOS
/// tab bar iterated `Tab.allCases`, so it shipped visible in every release
/// since. These tests exist because that claim went unchecked: the predicate
/// now lives in CLIPulseCore, where a test can reach it, rather than inside
/// an app-target SwiftUI view with no test bundle.
final class TabVisibilityTests: XCTestCase {

    func test_swarmIsNotOffered() {
        XCTAssertFalse(AppState.Tab.swarm.isVisible)
        XCTAssertFalse(AppState.Tab.visibleCases.contains(.swarm),
                       "the Swarm tab has no producer on any shipped helper — it cannot be offered")
    }

    /// The vacuity guard. A `visibleCases` that returned `[]` — or an
    /// `isVisible` that returned false for everything — would satisfy the
    /// test above while hiding the entire app.
    func test_everyOtherTabIsStillOffered() {
        let hidden = AppState.Tab.allCases.filter { !$0.isVisible }
        XCTAssertEqual(hidden, [.swarm],
                       "exactly one tab is meant to be hidden; found \(hidden)")
        XCTAssertEqual(AppState.Tab.visibleCases.count, AppState.Tab.allCases.count - 1)
        for tab in [AppState.Tab.overview, .machine, .providers, .sessions, .alerts, .pet, .settings] {
            XCTAssertTrue(AppState.Tab.visibleCases.contains(tab), "\(tab) must still be offered")
        }
    }

    /// `visibleCases` must preserve declaration order — the tab bar renders
    /// it directly, so a reordering here silently reshuffles the UI.
    func test_visibleCasesKeepsDeclarationOrder() {
        XCTAssertEqual(
            AppState.Tab.visibleCases,
            [.overview, .machine, .providers, .sessions, .alerts, .pet, .settings]
        )
    }

    /// SwiftUI's `TabView` renders nothing when `selection` matches no
    /// child's `.tag`, so selecting a hidden tab would be a blank screen
    /// rather than a missing one. Nothing sets `.swarm` any more, which is
    /// exactly why this guard exists: a future deep link or restored state
    /// would fail silently and far from `AppState`.
    @MainActor
    func test_selectingAHiddenTabFallsBackToOverview() {
        let state = AppState()

        state.selectedTab = .swarm
        XCTAssertEqual(state.selectedTab, .overview,
                       "a hidden tab must coerce to the dashboard, not render blank")

        // Control: a visible tab is left alone, so the coercion is not just
        // pinning everything to .overview.
        state.selectedTab = .alerts
        XCTAssertEqual(state.selectedTab, .alerts)
    }
}
