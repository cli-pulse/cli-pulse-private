import XCTest
import Combine
@testable import CLIPulseCore

/// Drives the real `AnonymousTelemetryCoordinator` — the real Combine
/// subscription, the real latch, the real actor — against a stub store and
/// transport.
///
/// Until v1.46 this type lived in the app target, which has no test bundle.
/// Nothing could reach it, so `ProviderPublisherSubscribeSemanticsTests`
/// re-implemented its operator chain and asserted against the copy. That copy
/// was faithful and the tests passed, and the shipped coordinator still lost
/// every first-launch activation event, because the defect was in the latch
/// *around* the chain rather than in the chain itself. Testing a replica cannot
/// find that class of bug; this file exists so the original is under test.
@MainActor
final class AnonymousTelemetryCoordinatorTests: XCTestCase {

    /// Counts entries into the actor's activation path by observing the first
    /// thing `recordFirstProviderDetectedIfNeeded` reads.
    ///
    /// Needed because "nothing was sent" is satisfied both by the gate refusing
    /// a delivered emission and by the Combine sink never delivering at all —
    /// and the tests below are about the first. Review demonstrated the gap by
    /// gutting the sink to `_ = hasProviders`: the headline test still passed,
    /// because a dead subscription produces the same zero sends as a closed
    /// gate. Counting the reads makes the sink's delivery observable.
    private final class Store: AnonymousTelemetryStore, @unchecked Sendable {
        var isEnabled = true
        var hasSeenDisclosure = false
        var installID = UUID(uuidString: "0BADCAFE-0000-4000-8000-0000000C0FFE")!
        var installReported = false
        var helperConnectedReported = false
        var costReported = false

        /// Incremented on every read. `recordFirstProviderDetectedIfNeeded`
        /// reads this first, so the count is the number of times the activation
        /// path was actually entered.
        private let lock = NSLock()
        private var storedActivationReported = false
        private var reads = 0

        var activationReported: Bool {
            get {
                lock.lock(); defer { lock.unlock() }
                reads += 1
                return storedActivationReported
            }
            set {
                lock.lock(); defer { lock.unlock() }
                storedActivationReported = newValue
            }
        }

        /// Reads without counting, for assertions about the end state.
        var activationReportedValue: Bool {
            lock.lock(); defer { lock.unlock() }
            return storedActivationReported
        }

        var activationPathEntries: Int {
            lock.lock(); defer { lock.unlock() }
            return reads
        }
    }

    private actor Transport: AnonymousTelemetryTransport {
        private(set) var sent: [AnonymousInstallPayload] = []
        func send(_ payload: AnonymousInstallPayload) async throws -> AnonymousInstallPayload.WireVersion {
            sent.append(payload)
            return payload.wireVersion
        }
        func payloads() -> [AnonymousInstallPayload] { sent }
        func activations() -> Int { sent.filter(\.providerDetected).count }
    }

    private func makeCoordinator(
        store: Store, transport: Transport
    ) -> AnonymousTelemetryCoordinator {
        AnonymousTelemetryCoordinator(
            telemetry: AnonymousInstallTelemetry(
                store: store, transport: transport, channel: .devid,
                rawAppVersion: "1.46.0", osMajor: 26, osMinor: 6
            )
        )
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

    /// The sink hops through `DispatchQueue.main` and then an unstructured
    /// `Task`, so settling needs a real yield rather than a single `await`.
    private func settle() async {
        for _ in 0..<50 {
            await Task.yield()
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
    }

    // MARK: -

    /// THE REGRESSION, end to end through the real object.
    ///
    /// Upgrade shape: providers are already flowing when the coordinator
    /// subscribes, hours before the user opens the menu. The sink fires against
    /// a closed gate. Then the user taps "Got it" — and activation must go out
    /// on this launch, not the next one.
    func test_activationIsSentOnTheLaunchTheDisclosureIsAcknowledged() async {
        let store = Store()                       // hasSeenDisclosure == false
        let transport = Transport()
        let providerState = ProviderState()
        providerState.providers = [makeProvider()] // already detected at subscribe time

        let coordinator = makeCoordinator(store: store, transport: transport)
        coordinator.start(observing: providerState)
        await settle()

        // The sink must have DELIVERED and been refused — not merely been
        // silent. Without this, gutting the subscription passes the test, since
        // a dead sink and a closed gate both produce zero sends.
        XCTAssertGreaterThan(
            store.activationPathEntries, 0,
            "the Combine sink never delivered; this test would then prove nothing"
        )

        // Gate was closed: nothing may have been sent, and nothing may be
        // recorded as sent.
        var count = await transport.payloads().count
        XCTAssertEqual(count, 0, "nothing may leave before the disclosure is acknowledged")
        XCTAssertFalse(store.activationReportedValue)
        XCTAssertFalse(store.installReported)

        // The user opens the menu and taps "Got it".
        store.hasSeenDisclosure = true
        coordinator.disclosureAcknowledged(providerState: providerState)
        await settle()

        let activations = await transport.activations()
        XCTAssertEqual(
            activations, 1,
            "v1.45 sent 0 here: the sink had already burned the latch against a refusal"
        )
        XCTAssertTrue(store.activationReportedValue)
        XCTAssertTrue(store.installReported)
        count = await transport.payloads().count
        XCTAssertEqual(count, 2, "one install, one activation")
    }

    /// Fresh-install shape: the card is acknowledged first, providers arrive
    /// afterwards. The sink must still deliver activation.
    func test_activationIsSentWhenProvidersArriveAfterAcknowledgement() async {
        let store = Store()
        let transport = Transport()
        let providerState = ProviderState()

        let coordinator = makeCoordinator(store: store, transport: transport)
        coordinator.start(observing: providerState)
        await settle()

        store.hasSeenDisclosure = true
        coordinator.disclosureAcknowledged(providerState: providerState)
        await settle()

        var activations = await transport.activations()
        XCTAssertEqual(activations, 0, "no providers yet, so no first value yet")
        XCTAssertTrue(store.installReported, "install goes out as soon as the card is dismissed")

        providerState.providers = [makeProvider()]
        await settle()

        activations = await transport.activations()
        XCTAssertEqual(activations, 1)
        XCTAssertTrue(store.activationReportedValue)
    }

    /// Once activation is DURABLY RECORDED, churn must not re-send.
    ///
    /// Scoped deliberately narrowly. Review showed this test stays green with
    /// the in-process `activationSent` guard deleted outright — because the
    /// persisted flag alone is enough once a send has succeeded. So it pins the
    /// post-record invariant, NOT the latch, and not the in-flight window: the
    /// stub transport returns instantly, so no second call can arrive while the
    /// first is still on the wire. That window is a known, server-idempotent
    /// redundancy (`install_id` is the PK and the activation timestamp is
    /// coalesced), not something this test claims to cover.
    func test_activationIsSentOnlyOnce() async {
        let store = Store()
        store.hasSeenDisclosure = true
        let transport = Transport()
        let providerState = ProviderState()

        let coordinator = makeCoordinator(store: store, transport: transport)
        coordinator.start(observing: providerState)
        await settle()

        providerState.providers = [makeProvider()]
        await settle()
        providerState.providers = [makeProvider(), makeProvider()]
        providerState.providers = []
        providerState.providers = [makeProvider()]
        await settle()

        let activations = await transport.activations()
        XCTAssertEqual(activations, 1, "first value happens once")
    }

    /// Opted out means silent, and the latch must not paper over it: nothing is
    /// sent and nothing is marked reported, so flipping the switch back on later
    /// still works.
    func test_optedOutSendsNothingAndStaysRetryable() async {
        let store = Store()
        store.hasSeenDisclosure = true
        store.isEnabled = false
        let transport = Transport()
        let providerState = ProviderState()

        let coordinator = makeCoordinator(store: store, transport: transport)
        coordinator.start(observing: providerState)
        providerState.providers = [makeProvider()]
        await settle()

        var count = await transport.payloads().count
        XCTAssertEqual(count, 0)
        XCTAssertFalse(store.activationReportedValue)

        store.isEnabled = true
        coordinator.disclosureAcknowledged(providerState: providerState)
        await settle()

        count = await transport.activations()
        XCTAssertEqual(count, 1, "a refusal must never be cached as a success")
    }
}
