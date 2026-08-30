import XCTest
@testable import CLIPulseCore

/// The v1.46 regression pin for the defect that made v1.45's activation counter
/// unreadable on the release that introduced it.
///
/// WHAT HAPPENED
/// -------------
/// `AnonymousTelemetryCoordinator` subscribes to `ProviderState.$providers` at
/// launch and calls `recordFirstProviderDetectedIfNeeded()` on the first
/// non-empty emission. On a first launch that call is refused — `maySend`
/// requires `hasSeenDisclosure`, and the disclosure card lives inside the
/// lazily-built `MenuBarExtra`, so it has not been shown yet. Nothing was sent
/// and the persisted `activationReported` correctly stayed false.
///
/// But the coordinator's in-process latch was set on *entry*, before the call,
/// so it recorded that it had tried rather than that it had succeeded. When the
/// user then opened the menu and tapped "Got it", `disclosureAcknowledged`
/// called back into the latched function and returned immediately. The Combine
/// sink could not rescue it either: `removeDuplicates()` stays latched on `true`
/// while the provider list stays non-empty.
///
/// Net effect: activation could never be reported on the launch where the card
/// is acknowledged — the only launch it is ever shown. It slipped to some later
/// launch, and was lost entirely for anyone who uninstalled before one. That
/// biased the funnel *pessimistically* for the v1.44 -> v1.45 upgrade wave that
/// dominated the first days of data, which is precisely the population whose
/// providers are already detected at launch.
///
/// WHY THE PIN LIVES HERE
/// ---------------------
/// The coordinator is in the app target, which has no test bundle — that is the
/// gap the defect came through, and the same one recorded for
/// `status_text`-style tautologies. So the decision it depends on was moved into
/// this type's return value, where it can be tested. `test_latchPolicy...`
/// below encodes the coordinator's rule directly so a future edit that reverts
/// to latch-on-attempt fails here rather than in production.
final class AnonymousActivationFirstLaunchTests: XCTestCase {

    private final class Store: AnonymousTelemetryStore, @unchecked Sendable {
        var isEnabled = true
        var hasSeenDisclosure = false
        var installID = UUID(uuidString: "0BADCAFE-0000-4000-8000-00000000FEED")!
        var installReported = false
        var activationReported = false
        var helperConnectedReported = false
        var costReported = false
    }

    private actor Transport: AnonymousTelemetryTransport {
        private(set) var sent: [AnonymousInstallPayload] = []
        var failEverything = false

        func setFailEverything(_ value: Bool) { failEverything = value }

        func send(_ payload: AnonymousInstallPayload) async throws -> AnonymousInstallPayload.WireVersion {
            if failEverything { throw URLError(.notConnectedToInternet) }
            sent.append(payload)
            return payload.wireVersion
        }

        func payloads() -> [AnonymousInstallPayload] { sent }
    }

    private func makeSubject(
        store: Store, transport: Transport
    ) -> AnonymousInstallTelemetry {
        AnonymousInstallTelemetry(
            store: store, transport: transport, channel: .devid,
            rawAppVersion: "1.46.0", osMajor: 26, osMinor: 6
        )
    }

    // MARK: - The contract the coordinator depends on

    /// A refusal must be reported as a refusal. Before v1.46 this returned
    /// `Void`, so "the gate said no" and "sent successfully" were the same
    /// observation at every call site — which is how the latch came to cache a
    /// send that never happened.
    func test_refusedActivationReportsNotRecorded() async {
        let store = Store()               // hasSeenDisclosure == false
        let transport = Transport()
        let recorded = await makeSubject(store: store, transport: transport)
            .recordFirstProviderDetectedIfNeeded()

        XCTAssertFalse(recorded, "the gate refused; the caller must be told to ask again")
        XCTAssertFalse(store.activationReported)
        let sent = await transport.payloads()
        XCTAssertTrue(sent.isEmpty, "nothing may leave before the disclosure is acknowledged")
    }

    /// A failed transport is also "ask again later", not "done".
    func test_failedSendReportsNotRecorded() async {
        let store = Store(); store.hasSeenDisclosure = true
        let transport = Transport(); await transport.setFailEverything(true)
        let recorded = await makeSubject(store: store, transport: transport)
            .recordFirstProviderDetectedIfNeeded()

        XCTAssertFalse(recorded)
        XCTAssertFalse(store.activationReported, "must stay retryable on the next launch")
    }

    /// Already-recorded reports `true` without sending again, so the caller can
    /// latch permanently and the RPC is not called once per provider edge.
    func test_alreadyRecordedReportsRecordedWithoutResending() async {
        let store = Store()
        store.hasSeenDisclosure = true
        store.activationReported = true
        let transport = Transport()
        let recorded = await makeSubject(store: store, transport: transport)
            .recordFirstProviderDetectedIfNeeded()

        XCTAssertTrue(recorded)
        let sent = await transport.payloads()
        XCTAssertTrue(sent.isEmpty)
    }

    // MARK: - The sequence that actually broke

    /// THE REGRESSION. Providers arrive before the menu has ever been opened
    /// (every upgrading user, and any fresh install whose scan wins the race),
    /// then the user acknowledges the card. Activation must go out on THIS
    /// launch.
    func test_activationSurvivesTheLaunchOnWhichTheDisclosureIsAcknowledged() async {
        let store = Store()
        let transport = Transport()
        let subject = makeSubject(store: store, transport: transport)

        // t0 — launch. The coordinator's sink fires on the first non-empty
        // provider list. The card has not been shown, so this is refused.
        let atLaunch = await subject.recordFirstProviderDetectedIfNeeded()
        XCTAssertFalse(atLaunch)
        XCTAssertFalse(store.activationReported)
        let beforeCard = await transport.payloads()
        XCTAssertTrue(beforeCard.isEmpty)

        // t1 — the user opens the menu and taps "Got it". MenuBarView writes the
        // flag, then calls AnonymousTelemetryCoordinator.disclosureAcknowledged,
        // which records the install and re-reports activation.
        store.hasSeenDisclosure = true
        await subject.recordInstallIfNeeded()
        let afterAcknowledgement = await subject.recordFirstProviderDetectedIfNeeded()

        XCTAssertTrue(
            afterAcknowledgement,
            "activation must not be deferred to a later launch"
        )
        XCTAssertTrue(store.activationReported)
        let sent = await transport.payloads()
        XCTAssertTrue(
            sent.contains { $0.providerDetected },
            "an activation payload must have reached the transport on this launch"
        )
    }

    // A `test_latchPolicyMustCacheTheOutcomeNotTheAttempt` used to sit here. It
    // re-implemented BOTH latch policies inside the test body and asserted they
    // disagreed — so it passed with the production fix fully reverted, while its
    // docstring claimed to pin production. Review caught it by mutation testing.
    // A test that constrains only itself is worse than no test, because it reads
    // like coverage. The real pin is `AnonymousTelemetryCoordinatorTests`, which
    // drives the actual coordinator: reverting the latch fails 4 of its 4 tests.

    /// Install has the same contract, and the same first-launch shape: refused
    /// at launch, sent once the card is acknowledged.
    func test_installIsRecordedOnceTheDisclosureIsAcknowledged() async {
        let store = Store()
        let transport = Transport()
        let subject = makeSubject(store: store, transport: transport)

        let beforeCard = await subject.recordInstallIfNeeded()
        XCTAssertFalse(beforeCard)
        XCTAssertFalse(store.installReported)

        store.hasSeenDisclosure = true
        let afterCard = await subject.recordInstallIfNeeded()
        XCTAssertTrue(afterCard)
        XCTAssertTrue(store.installReported)

        // A second call is a no-op that still reports "recorded".
        let repeated = await subject.recordInstallIfNeeded()
        XCTAssertTrue(repeated)
        let sent = await transport.payloads()
        XCTAssertEqual(sent.count, 1, "the install must not be sent twice")
    }
}
