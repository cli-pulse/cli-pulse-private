import XCTest
import Combine
@testable import CLIPulseCore

/// Settles a review claim about the activation counter, empirically.
///
/// A reviewer argued that upgrading users can never fire
/// `first_provider_detected`: their providers are *already* detected, so
/// `providerState.$providers` supposedly never transitions to non-empty and the
/// sink never runs. If that were true, every upgrade would inflate the
/// denominator with a permanently unactivatable row and the funnel would read
/// near zero for reasons that have nothing to do with the product.
///
/// It is worth an actual test rather than an argument from documentation,
/// because the whole point of the v1.45 telemetry is that we could not tell a
/// broken counter from a broken product.
///
/// These tests reproduce the exact chain used by AnonymousTelemetryCoordinator.
/// That type lives in the app target and cannot be imported here, so the chain
/// is duplicated — if it changes there, change it here too.
///
/// Worth recording while here: `ProviderState` is `@MainActor`-isolated, so
/// `providers` can only be mutated on the main actor and the publisher always
/// delivers there. The `.receive(on: DispatchQueue.main)` added to the
/// coordinator during the v1.45 smoke is therefore belt-and-braces, not a fix
/// for a live race — the race it guards against cannot occur while that
/// isolation holds. It stays, because it makes the requirement explicit rather
/// than dependent on a declaration in another file.
@MainActor
final class ProviderPublisherSubscribeSemanticsTests: XCTestCase {

    private var bag = Set<AnyCancellable>()

    private func observe(
        _ state: ProviderState,
        onActive: @escaping () -> Void
    ) {
        state.$providers
            .map { !$0.isEmpty }
            .removeDuplicates()
            .sink { if $0 { onActive() } }
            .store(in: &bag)
    }

    private func makeProvider() -> ProviderUsage {
        ProviderUsage(
            provider: ProviderKind.claude.rawValue,
            today_usage: 1, week_usage: 1,
            estimated_cost_today: 0, estimated_cost_week: 0,
            cost_status_today: "Unavailable", cost_status_week: "Unavailable",
            quota: 100, remaining: 99, plan_type: "Max", reset_time: nil,
            tiers: [], status_text: "test",
            trend: [], recent_sessions: [], recent_errors: []
        )
    }

    /// The fresh-install shape: empty at subscribe, populated later.
    func test_firesWhenProvidersArriveAfterSubscribing() {
        let state = ProviderState()
        var fired = 0
        observe(state) { fired += 1 }

        XCTAssertEqual(fired, 0, "an empty list must not count as activation")
        state.providers = [makeProvider()]
        XCTAssertEqual(fired, 1)
    }

    /// THE CLAIM. The upgrade shape: providers already present before the
    /// coordinator subscribes. `@Published` delivers its current value to each
    /// new subscriber, so the sink runs immediately — the transition the
    /// reviewer expected is not required.
    func test_firesWhenProvidersAreAlreadyPresentAtSubscribeTime() {
        let state = ProviderState()
        state.providers = [makeProvider()]

        var fired = 0
        observe(state) { fired += 1 }

        XCTAssertEqual(
            fired, 1,
            "an upgrading user whose providers are already detected must still be counted"
        )
    }

    /// `removeDuplicates` must not let a churning provider list re-fire. The
    /// durable guarantee is the persisted flag, but this keeps the in-process
    /// path from queueing redundant work.
    func test_doesNotRefireWhileTheListStaysNonEmpty() {
        let state = ProviderState()
        var fired = 0
        observe(state) { fired += 1 }

        state.providers = [makeProvider()]
        state.providers = [makeProvider(), makeProvider()]
        state.providers = [makeProvider()]

        XCTAssertEqual(fired, 1)
    }

    /// Going empty and back again is one more activation edge. Harmless — the
    /// persisted flag makes the second one a no-op — but assert the shape so a
    /// future change to the operator chain is a visible decision.
    func test_emptyingAndRefillingProducesASecondEdge() {
        let state = ProviderState()
        var fired = 0
        observe(state) { fired += 1 }

        state.providers = [makeProvider()]
        state.providers = []
        state.providers = [makeProvider()]

        XCTAssertEqual(fired, 2, "guarded downstream by the persisted activation flag")
    }
}
