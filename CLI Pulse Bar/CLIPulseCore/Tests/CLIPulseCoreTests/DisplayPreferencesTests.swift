import XCTest
@testable import CLIPulseCore

/// The UI language and the display currency are process-wide state every later
/// test inherits, so under XCTest they must not come from the `xctest` tool's
/// defaults domain, which every test run on the Mac shares. On 2026-09-29 a
/// Japanese choice some earlier run left there turned `ClaudeStrategyTests` and
/// `ConversationPreviewRouterTests` red, suites that never touch the language.
/// See `DisplayPreferences`.
///
/// These tests never write to `UserDefaults.standard`: that domain is the thing
/// being protected, and a write that an interrupted run failed to take back is
/// how the problem started.
final class DisplayPreferencesTests: XCTestCase {

    override func tearDown() {
        LocaleOverrideStore.shared.set(nil)
        DisplayPreferences.defaults.removeObject(forKey: DisplayCurrency.defaultsKey)
        super.tearDown()
    }

    /// The app keeps both choices where it always has.
    func test_outsideXCTest_bothChoicesStayInStandardDefaults() {
        XCTAssertTrue(DisplayPreferences.resolve(runningUnderXCTest: false) === UserDefaults.standard)
    }

    func test_underXCTest_theChoicesAreNotInTheRunnersSharedDomain() {
        XCTAssertFalse(DisplayPreferences.defaults === UserDefaults.standard)
    }

    /// A choice made in a test lands in the tests' domain, not in the runner's,
    /// where the next run on the Mac would start from it.
    func test_aLanguageChosenInATestIsKeptInTheTestsDomain() {
        LocaleOverrideStore.shared.set(nil)
        LocaleOverrideStore.shared.set("ko")

        XCTAssertEqual(DisplayPreferences.defaults.string(forKey: LocaleOverrideStore.defaultsKey), "ko")
        XCTAssertNotEqual(UserDefaults.standard.string(forKey: LocaleOverrideStore.defaultsKey), "ko",
                          "LocaleOverrideStore.shared wrote to the xctest tool's shared domain")
    }

    /// What a new test process sees when an earlier run was stopped with a
    /// language and a currency still chosen.
    func test_aNewTestProcessStartsInSystemDefaultAndDollars_whateverTheLastRunLeft() throws {
        let leftover = try XCTUnwrap(UserDefaults(suiteName: DisplayPreferences.xctestSuiteName))
        leftover.set("ja", forKey: LocaleOverrideStore.defaultsKey)
        leftover.set("JPY", forKey: DisplayCurrency.defaultsKey)
        // Positive control: the leftovers are really there to be read.
        XCTAssertEqual(LocaleOverrideStore(defaults: leftover).override, "ja")
        XCTAssertEqual(DisplayCurrency.stored(in: leftover), .jpy)

        let fresh = DisplayPreferences.resolve(runningUnderXCTest: true)

        XCTAssertNil(LocaleOverrideStore(defaults: fresh).override)
        XCTAssertEqual(DisplayCurrency.stored(in: fresh), .usd)
    }

    /// Every `AppState` pushes its currency into `CurrencyConverter.shared`, so
    /// the currency has to be read from the same place as the language.
    @MainActor
    func test_appStateAndStoredReadTheCurrencyFromTheTestsDomain() throws {
        let suite = "DisplayPreferencesTests.\(UUID().uuidString)"
        let scratch = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { scratch.removePersistentDomain(forName: suite) }

        DisplayPreferences.defaults.set("EUR", forKey: DisplayCurrency.defaultsKey)
        let state = AppState(
            runtimeEnvironment: .resolveForTesting(infoDictionary: [:], environment: [:]),
            defaults: scratch,
            performLaunchSetup: false)

        XCTAssertEqual(state.displayCurrency, .eur)
        XCTAssertEqual(DisplayCurrency.stored(), .eur)
    }
}
