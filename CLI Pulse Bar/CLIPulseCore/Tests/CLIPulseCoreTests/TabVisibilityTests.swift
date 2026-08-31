import XCTest
@testable import CLIPulseCore

/// A4 (2026-08-30) hid the Swarm tab; v1.52.1 deleted its source outright.
///
/// It was a top-level tab on macOS and iOS that could never contain anything —
/// swarm rows arrived via `remote_helper_swarm_heartbeat`, which no shipped
/// helper ever called, and production `remote_swarms` was 0 rows.
///
/// v1.22.0's release notes said it was dark-shipped. It was not: the macOS tab
/// bar iterated `Tab.allCases`, so it shipped visible in every release for
/// thirty versions. That is why the visibility mechanism survives the tab it
/// was built for — and why these tests live in CLIPulseCore, where they can
/// reach the predicate. The claim went unchecked precisely because it lived
/// inside an app-target SwiftUI view with no test bundle.
final class TabVisibilityTests: XCTestCase {

    /// The tab is gone from the model entirely, not merely hidden.
    func test_swarmIsNotATabAnyMore() {
        XCTAssertNil(AppState.Tab(rawValue: "Swarm"))
        XCTAssertFalse(AppState.Tab.allCases.contains { $0.rawValue == "Swarm" })
    }

    /// Every tab that exists is offered. This is the state the mechanism is
    /// *supposed* to be in — and it is an assertion, not a tautology: it fails
    /// the moment someone adds a case without deciding whether users see it.
    func test_everyTabIsOffered() {
        XCTAssertEqual(AppState.Tab.visibleCases, AppState.Tab.allCases)
        XCTAssertFalse(AppState.Tab.visibleCases.isEmpty)
    }

    /// Tab bars render `visibleCases` directly, so its order IS the UI order.
    func test_visibleCasesKeepsDeclarationOrder() {
        XCTAssertEqual(
            AppState.Tab.visibleCases,
            [.overview, .machine, .providers, .sessions, .alerts, .pet, .settings]
        )
    }

    /// SwiftUI's `TabView` renders nothing when `selection` matches no child's
    /// `.tag`, so a hidden tab would be a blank screen rather than a missing
    /// one. Nothing can select a hidden tab today — which is exactly why the
    /// guard stays: a future hidden tab reached by a deep link or restored
    /// state would fail silently and far from `AppState`.
    @MainActor
    func test_selectingAHiddenTabWouldFallBackToOverview() {
        let state = AppState()
        for tab in AppState.Tab.allCases where !tab.isVisible {
            state.selectedTab = tab
            XCTAssertEqual(state.selectedTab, .overview, "\(tab) must coerce to the dashboard")
        }
        // Control: a visible tab is left alone, so the coercion is not pinning
        // everything to .overview.
        state.selectedTab = .alerts
        XCTAssertEqual(state.selectedTab, .alerts)
    }
}
