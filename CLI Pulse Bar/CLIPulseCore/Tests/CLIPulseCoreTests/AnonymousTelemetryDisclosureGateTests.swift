import XCTest
@testable import CLIPulseCore

/// The disclosure gate, tested as the load-bearing thing it is.
///
/// The switch ships ON. The *entire* justification for that is the card shown
/// on first launch — so "nothing is sent before the card has been seen" cannot
/// be a convention, it has to be a property of the code. These tests exercise
/// the real store rather than a stub, because the stub cannot catch a wrong
/// default or a key that reads back differently than it was written.
final class AnonymousTelemetryDisclosureGateTests: XCTestCase {

    private actor CountingTransport: AnonymousTelemetryTransport {
        private(set) var count = 0
        func send(_ payload: AnonymousInstallPayload) async throws { count += 1 }
        func sends() -> Int { count }
    }

    private func scratchDefaults() -> UserDefaults {
        let suite = "anon-disclosure-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return defaults
    }

    private func subject(
        _ store: AnonymousTelemetryStore,
        _ transport: CountingTransport
    ) -> AnonymousInstallTelemetry {
        AnonymousInstallTelemetry(
            store: store, transport: transport, channel: .devid,
            rawAppVersion: "1.45.0", osMajor: 15, osMinor: 1
        )
    }

    /// A pristine install — exactly the state a first launch is in.
    func test_aFreshInstallSendsNothingUntilTheCardIsAcknowledged() async {
        let store = UserDefaultsAnonymousTelemetryStore(defaults: scratchDefaults())
        let transport = CountingTransport()

        // Launch. The menu has not been opened, so the card has not been shown.
        await subject(store, transport).recordInstallIfNeeded()
        var sends = await transport.sends()
        XCTAssertEqual(sends, 0, "the default-on switch must not outrun the disclosure")

        // Even discovering a provider must not force it out early.
        await subject(store, transport).recordFirstProviderDetectedIfNeeded()
        sends = await transport.sends()
        XCTAssertEqual(sends, 0, "activation is not an exception to the gate")

        // User opens the menu, reads the card, clicks "Got it".
        store.hasSeenDisclosure = true
        await subject(store, transport).recordInstallIfNeeded()
        sends = await transport.sends()
        XCTAssertEqual(sends, 1, "acknowledging the card releases the gate")
    }

    /// Someone who reads the card and switches it off in the same breath. The
    /// toggle is inside the card precisely so this is possible, and it has to
    /// work — acknowledging is not consenting.
    func test_optingOutOnTheCardItselfSendsNothingEver() async {
        let defaults = scratchDefaults()
        let store = UserDefaultsAnonymousTelemetryStore(defaults: defaults)
        let transport = CountingTransport()

        defaults.set(false, forKey: UserDefaultsAnonymousTelemetryStore.enabledKey)
        store.hasSeenDisclosure = true

        await subject(store, transport).recordInstallIfNeeded()
        await subject(store, transport).recordFirstProviderDetectedIfNeeded()
        let sends = await transport.sends()
        XCTAssertEqual(sends, 0)
    }

    /// The flag has to survive a relaunch, or the card reappears every launch
    /// and the gate re-closes behind it.
    func test_theAcknowledgementPersists() {
        let defaults = scratchDefaults()
        UserDefaultsAnonymousTelemetryStore(defaults: defaults).hasSeenDisclosure = true
        XCTAssertTrue(UserDefaultsAnonymousTelemetryStore(defaults: defaults).hasSeenDisclosure)
    }

    /// Local-only mode is checked at send time, not captured at construction,
    /// so switching it on mid-session takes effect immediately rather than at
    /// the next launch.
    func test_turningOnLocalOnlyModeStopsSendsImmediately() async {
        let defaults = scratchDefaults()
        let store = UserDefaultsAnonymousTelemetryStore(defaults: defaults)
        store.hasSeenDisclosure = true
        let transport = CountingTransport()
        let telemetry = subject(store, transport)

        defaults.set(true, forKey: "privacy.localOnlyMode")
        await telemetry.recordInstallIfNeeded()

        let sends = await transport.sends()
        XCTAssertEqual(sends, 0, "the gate must be evaluated per send, not cached")
    }
}
