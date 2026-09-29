import XCTest
@testable import CLIPulseCore

/// The UI language and the display currency are process-wide state every later
/// test inherits, so under XCTest they must not come from the `xctest` tool's
/// defaults domain, which every test run on the Mac shares. On 2026-09-29 a
/// Japanese choice some earlier run left there turned `ClaudeStrategyTests` and
/// `ConversationPreviewRouterTests` red, suites that never touch the language.
/// See `DisplayPreferences`.
///
/// These tests write nothing to `UserDefaults.standard`, which is the domain
/// being protected, and nothing to `DisplayPreferences.defaults`, which test runs
/// going at the same moment share and each new one empties: a value written there
/// and read back can be gone in between. The wiring is checked by comparing the
/// stores themselves, and the emptying on a domain of the test's own.
final class DisplayPreferencesTests: XCTestCase {

    /// The app keeps both choices where it always has.
    func test_outsideXCTest_bothChoicesStayInStandardDefaults() {
        XCTAssertTrue(DisplayPreferences.resolve(runningUnderXCTest: false) === UserDefaults.standard)
    }

    func test_underXCTest_theChoicesAreNotInTheRunnersSharedDomain() {
        XCTAssertFalse(DisplayPreferences.defaults === UserDefaults.standard)
    }

    /// `L10n` reads the language through `LocaleOverrideStore.shared`.
    func test_theLanguageIsKeptInDisplayPreferences() {
        XCTAssertTrue(LocaleOverrideStore.shared.defaults === DisplayPreferences.defaults,
                      "LocaleOverrideStore.shared keeps the language outside DisplayPreferences")
    }

    /// Every `AppState` pushes its currency into `CurrencyConverter.shared`, so
    /// the currency has to be kept in the same place as the language.
    /// `AppState.displayCurrencyRaw` and `DisplayCurrency.stored()` both read
    /// `DisplayCurrency.store`.
    func test_theCurrencyIsKeptInDisplayPreferences() {
        XCTAssertTrue(DisplayCurrency.store === DisplayPreferences.defaults,
                      "the display currency is kept outside DisplayPreferences")
    }

    /// What a new test process sees when an earlier run was stopped with a
    /// language and a currency still chosen. On a domain of this test's own, so
    /// it never empties the shared one under a run going at the same moment.
    func test_aNewTestProcessStartsInSystemDefaultAndDollars_whateverTheLastRunLeft() throws {
        let suiteName = "DisplayPreferencesTests.\(UUID().uuidString)"
        let leftover = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { leftover.removePersistentDomain(forName: suiteName) }
        leftover.set("ja", forKey: LocaleOverrideStore.defaultsKey)
        leftover.set("JPY", forKey: DisplayCurrency.defaultsKey)
        // Positive control: the leftovers are really there to be read.
        XCTAssertEqual(LocaleOverrideStore(defaults: leftover).override, "ja")
        XCTAssertEqual(DisplayCurrency.stored(in: leftover), .jpy)

        let fresh = DisplayPreferences.resolve(runningUnderXCTest: true, suiteName: suiteName)

        XCTAssertNil(LocaleOverrideStore(defaults: fresh).override)
        XCTAssertEqual(DisplayCurrency.stored(in: fresh), .usd)
    }
}
