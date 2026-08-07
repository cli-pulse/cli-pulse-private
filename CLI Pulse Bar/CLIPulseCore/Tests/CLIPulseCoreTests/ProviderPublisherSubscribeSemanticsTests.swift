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
/// These tests reproduce the operator chain used by
/// AnonymousTelemetryCoordinator, to pin `@Published` subscribe semantics on
/// their own.
///
/// v1.46: they used to be duplicated here because that type lived in the app
/// target and could not be imported. It now lives in CLIPulseCore, and
/// `AnonymousTelemetryCoordinatorTests` drives the real object — which is the
/// file to change when the coordinator changes. These stay as a focused pin on
/// Combine's behaviour, and as the record of a review claim that was settled
/// empirically. Testing this replica was NOT sufficient: the chain below was a
/// faithful copy and passed, while the shipped coordinator lost every
/// first-launch activation to a latch that sits outside the chain.
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

    /// Going empty and back again is one more activation edge. Harmless, but
    /// assert the shape so a future change to the operator chain is a visible
    /// decision.
    ///
    /// This used to say the second edge is "guarded downstream by the persisted
    /// activation flag". It is not: the coordinator's in-process `activationSent`
    /// latch is hit first and the actor is never reached. That mattered — the
    /// v1.45 defect was that the latch could be set without anything having been
    /// persisted, so "the persisted flag will catch it" was load-bearing and
    /// wrong. See `AnonymousTelemetryCoordinatorTests`.
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
