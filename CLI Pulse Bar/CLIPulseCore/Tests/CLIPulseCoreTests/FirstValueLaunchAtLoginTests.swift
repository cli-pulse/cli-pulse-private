#if os(macOS)
import XCTest
@testable import CLIPulseCore

/// v1.44 W5 — pin when the app is allowed to make itself a login item.
///
/// This is the most intrusive thing in the release: a background app adding
/// itself to the user's startup without being asked. The tests exist because
/// every guard below is the difference between "reasonable default" and
/// "behaves like adware", and three of them are invisible until they fail on
/// someone's actual Mac.
final class FirstValueLaunchAtLoginTests: XCTestCase {

    private func decide(
        producedValue: Bool = true,
        alreadyEnabled: Bool = false,
        alreadyAutoEnabled: Bool = false,
        userTouchedToggle: Bool = false
    ) -> FirstValueLaunchAtLogin.Decision {
        FirstValueLaunchAtLogin.decide(
            producedValue: producedValue,
            alreadyEnabled: alreadyEnabled,
            alreadyAutoEnabled: alreadyAutoEnabled,
            userTouchedToggle: userTouchedToggle
        )
    }

    /// The one case that should fire: we just showed them real numbers, and
    /// they have expressed no preference either way.
    func testEnablesOnceAfterTheAppHasActuallyShownSomething() {
        XCTAssertEqual(decide(), .enableAndNotify)
    }

    /// The guard that matters most. Re-enabling something a person deliberately
    /// switched off is how an app earns a one-star review, and it is the exact
    /// behaviour users mean when they call software "sneaky".
    func testAUserWhoTurnedItOffIsNeverOverridden() {
        XCTAssertEqual(decide(userTouchedToggle: true), .skip)
    }

    /// Also true when they turned it ON themselves — we must not then claim
    /// credit with a notice for something they did.
    func testAUserWhoTurnedItOnThemselvesGetsNoNotice() {
        XCTAssertEqual(decide(alreadyEnabled: true, userTouchedToggle: true), .skip)
    }

    /// One-shot for the lifetime of the install. Without this the notice
    /// reappears on every launch that produces data, which is nagging.
    func testItOnlyEverHappensOnce() {
        XCTAssertEqual(decide(alreadyAutoEnabled: true), .skip)
    }

    /// No value, no login item. An app that has shown the user nothing has not
    /// earned a permanent slot on their machine, and this is the guard that
    /// keeps the feature defensible: a user who never gets data never gets a
    /// login item they'd have to go hunting for.
    func testNothingHappensBeforeTheAppHasProvedUseful() {
        XCTAssertEqual(decide(producedValue: false), .skip)
    }

    /// Idempotence against reality: if the item is already registered there is
    /// nothing to do and nothing to announce.
    func testAlreadyRegisteredIsLeftAlone() {
        XCTAssertEqual(decide(alreadyEnabled: true), .skip)
    }

    // MARK: - what counts as "value"

    func testRealNumbersCountAsValue() {
        XCTAssertTrue(FirstValueLaunchAtLogin.producedValue([.codex: .producedData]))
    }

    /// `ranButEmpty` is the silent-zero case — a collector that ran and
    /// returned nothing. Counting it would mean adding a login item for an app
    /// that is showing the user a blank screen, which is precisely backwards.
    func testAnEmptyRunIsNotValue() {
        XCTAssertFalse(FirstValueLaunchAtLogin.producedValue([.codex: .ranButEmpty]))
    }

    func testFailuresAndNotReadyAreNotValue() {
        XCTAssertFalse(FirstValueLaunchAtLogin.producedValue([
            .codex: .failed(.auth),
            .claude: .notReady(.missingCredentials),
            .gemini: .disabled,
            .cursor: .unsupported,
        ]))
    }

    /// One working provider is enough — the user is seeing numbers.
    func testOneWorkingProviderAmongFailuresIsStillValue() {
        XCTAssertTrue(FirstValueLaunchAtLogin.producedValue([
            .codex: .failed(.network),
            .claude: .producedData,
        ]))
    }

    func testNoProvidersAtAllIsNotValue() {
        XCTAssertFalse(FirstValueLaunchAtLogin.producedValue([:]))
    }

    /// The two defaults keys must not collide, or recording "the user chose"
    /// would also mark "we already auto-enabled" and vice versa.
    func testTheTwoMarkersAreDistinct() {
        XCTAssertNotEqual(
            FirstValueLaunchAtLogin.didAutoEnableKey,
            FirstValueLaunchAtLogin.userTouchedToggleKey
        )
    }
}
#endif
