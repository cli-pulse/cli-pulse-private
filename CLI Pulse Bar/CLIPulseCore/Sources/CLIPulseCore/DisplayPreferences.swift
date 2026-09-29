import Foundation

/// Where the two choices that every screen reads through process-wide state are
/// kept: the UI language (`LocaleOverrideStore.shared`) and the display currency
/// (`AppState.displayCurrency`, which sets `CurrencyConverter.shared`).
///
/// In the app, and in any process XCTest is not loaded into, this is
/// `UserDefaults.standard`, where both have always lived.
///
/// Under XCTest it is a domain of the tests' own, emptied the first time the test
/// process uses it. `swift test` runs the bundle inside Xcode's `xctest` tool, so
/// there `.standard` is `com.apple.dt.xctest.tool`: one domain for every test run
/// of every checkout on the Mac. A run that chose Japanese and was stopped before
/// putting the choice back left `cli_pulse_locale_override` there, and every later
/// run, of any branch, started in Japanese. Suites that never choose a language
/// and assert English, because English is what the system gives them, failed:
/// `ClaudeStrategyTests` and `ConversationPreviewRouterTests` on 2026-09-29. A
/// display currency left there turns "$9.57" into "¥1,505" the same way, in
/// `CostFormatterTests` and `WatchPulseFormatTests`. Which suites fail depends on
/// the order they run in: the first suite that resets the language hides the
/// leftover from every suite after it, so a filtered run can fail where the full
/// run passes.
///
/// Only these two, because they are the stored values that become process-wide
/// state for every later test. On 2026-09-30, 31 other app keys the suite reads
/// from `.standard` (the privacy switches, demo mode, the refresh interval, the
/// cached FX rates, ...) were planted in that domain with non-default values, and
/// none changed a result.
///
/// One fixed name rather than one per process: a domain is a file in
/// `~/Library/Preferences`, and removing the domain leaves the file behind.
/// Emptying it at first use is what makes each run start from System Default and
/// dollars. Runs going at the same moment still share it after that, so a test
/// that sets either choice puts it back, as before.
@usableFromInline
enum DisplayPreferences {
    /// `@usableFromInline` because `DisplayCurrency.stored(in:)`, which is public,
    /// takes it as its default argument.
    @usableFromInline
    static let defaults: UserDefaults = resolve(
        runningUnderXCTest: NSClassFromString("XCTestCase") != nil
    )

    /// The tests' domain. Not an app key, so it needs no `cli_pulse_` prefix:
    /// `UnsandboxedDataMigration` never sees it, because the app never uses it.
    static let xctestSuiteName = "clipulse.xctest.display-preferences"

    /// `defaults`, for a given answer to "is XCTest loaded", so a test can pin
    /// what the app gets without being the app.
    static func resolve(runningUnderXCTest: Bool) -> UserDefaults {
        guard runningUnderXCTest else { return .standard }
        guard let suite = UserDefaults(suiteName: xctestSuiteName) else {
            // Only the app's own identifier or NSGlobalDomain is refused, and this
            // name is neither. Falling back to `.standard` would bring back the
            // leak without a sound.
            preconditionFailure("UserDefaults refused the suite \(xctestSuiteName)")
        }
        suite.removePersistentDomain(forName: xctestSuiteName)
        return suite
    }
}
